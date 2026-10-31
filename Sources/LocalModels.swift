import AppKit
import CryptoKit
import NaturalLanguage

/// A translation model that runs on this Mac through the bundled llama.cpp server.
/// The catalog, prompt formats and server settings live in shared/models.json, which the
/// Windows app reads too, so both offer the same models with the same ratings and prompts.
struct LocalModel: Identifiable, Hashable, Decodable {
    let id: String
    let name: String
    let maker: String
    let summary: String
    let repo: String
    let file: String
    let sha256: String
    let bytes: Int64
    let ramGB: Int           // smallest Mac (unified memory) it runs comfortably on
    let languages: Int
    let prompt: String       // key into Catalog.prompts
    let speed: Int           // 1-5 (0 = not rated yet); see bench/BENCHMARKS.md
    let accuracy: Int
    let recommended: Bool    // suggested for most Macs
    let tested: Bool         // ratings measured by bench/, not estimated
    let license: String
    let badge: String?       // what it is best at, shown on recommended models
    let supported: String?   // key into Catalog.languageSets; nil = every language

    var url: URL { URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file)")! }
    var sizeText: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    func supports(_ l: Language) -> Bool {
        guard let key = supported else { return true }
        return Catalog.shared.languageSets[key]?.contains(l.code) ?? true
    }

    static var catalog: [LocalModel] { Catalog.shared.models }
    static func named(_ id: String) -> LocalModel? { catalog.first { $0.id == id } }

    static var macRAMGB: Int { Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded()) }
    static var isAppleSilicon: Bool {
        var v: Int32 = 0; var n = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &v, &n, nil, 0) == 0 && v == 1
    }
}

// MARK: - Storage and downloads

@MainActor
final class ModelStore: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = ModelStore()

    @Published private(set) var progress: [String: Double] = [:]   // id -> 0...1 while downloading
    @Published private(set) var verifying: Set<String> = []
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var installed: Set<String> = []

    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var resumeData: [String: Data] = [:]
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)

    nonisolated static let folder: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lingveil/Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    override init() {
        super.init()
        refresh()
    }

    func path(_ m: LocalModel) -> URL { Self.folder.appendingPathComponent(m.file) }
    func isInstalled(_ m: LocalModel) -> Bool { installed.contains(m.id) }

    func refresh() {
        installed = Set(LocalModel.catalog.filter { FileManager.default.fileExists(atPath: path($0).path) }.map(\.id))
    }

    func download(_ m: LocalModel) {
        errors[m.id] = nil
        let free = (try? Self.folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? .max
        guard free > m.bytes + 1_000_000_000 else { errors[m.id] = "Not enough free disk space"; return }
        let t = resumeData[m.id].map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: m.url)
        t.taskDescription = m.id
        tasks[m.id] = t
        progress[m.id] = 0
        t.resume()
    }

    func cancel(_ m: LocalModel) {
        tasks[m.id]?.cancel { [weak self] data in Task { @MainActor in self?.resumeData[m.id] = data } }
        tasks[m.id] = nil
        progress[m.id] = nil
    }

    func delete(_ m: LocalModel) {
        if Prefs.localModel == m.id { LlamaServer.shared.stop() }
        try? FileManager.default.removeItem(at: path(m))
        refresh()
    }

    nonisolated func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask, didWriteData _: Int64,
                                totalBytesWritten done: Int64, totalBytesExpectedToWrite total: Int64) {
        guard let id = t.taskDescription, total > 0 else { return }
        MainActor.assumeIsolated { progress[id] = Double(done) / Double(total) }
    }

    nonisolated func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask, didFinishDownloadingTo tmp: URL) {
        guard let id = t.taskDescription, let m = LocalModel.named(id) else { return }
        // The temp file is deleted when this returns, so move it first and verify afterwards.
        let staged = ModelStore.folder.appendingPathComponent(m.file + ".part")
        try? FileManager.default.removeItem(at: staged)
        do { try FileManager.default.moveItem(at: tmp, to: staged) } catch { return }
        MainActor.assumeIsolated { verifying.insert(id) }
        Task.detached(priority: .utility) {
            let ok = ModelStore.sha256(of: staged)?.hasPrefix(m.sha256) == true
            await MainActor.run {
                self.verifying.remove(id)
                self.progress[id] = nil
                self.tasks[id] = nil
                if ok {
                    try? FileManager.default.moveItem(at: staged, to: self.path(m))
                } else {
                    try? FileManager.default.removeItem(at: staged)
                    self.errors[id] = "The download was damaged; try again"
                }
                self.refresh()
            }
        }
    }

    nonisolated func urlSession(_ s: URLSession, task t: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = t.taskDescription else { return }
        let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        MainActor.assumeIsolated {
            if (error as NSError).code != NSURLErrorCancelled { errors[id] = error.localizedDescription }
            resumeData[id] = data
            progress[id] = nil
            tasks[id] = nil
        }
    }

    nonisolated static func sha256(of url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try? h.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Runtime

/// Runs the bundled llama.cpp server for the chosen model. It starts on first use and stops
/// after a few idle minutes (or when macOS reports memory pressure), so the model's memory
/// is only held while translations are actually happening.
actor LlamaServer {
    static let shared = LlamaServer()
    static var idleStop: TimeInterval { TimeInterval(Catalog.shared.server.idleStopSeconds) }

    private var process: Process?
    private var port = 0
    private var modelID: String?
    private var lastUse = Date()
    private var idleTask: Task<Void, Never>?
    private var pressure: DispatchSourceMemoryPressure?

    static var binary: URL? {
        let u = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/llama-server")
        return FileManager.default.isExecutableFile(atPath: u.path) ? u : nil
    }

    private var starting: Task<URL, Error>?
    private var failedAt: [String: Date] = [:]

    /// Base URL of a server running `m`, starting it if needed. Concurrent callers share
    /// one start; a model that failed to start isn't retried for half a minute.
    func endpoint(for m: LocalModel) async throws -> URL {
        lastUse = Date()
        if let p = process, p.isRunning, modelID == m.id, starting == nil { return URL(string: "http://127.0.0.1:\(port)")! }
        if let t = starting, modelID == m.id { return try await t.value }
        if let f = failedAt[m.id], Date().timeIntervalSince(f) < 30 { throw LingveilError.message("\(m.name) could not start") }
        stopNow()
        modelID = m.id
        let t = Task { try await launch(m) }
        starting = t
        defer { starting = nil }
        do { return try await t.value }
        catch { failedAt[m.id] = Date(); stopNow(); throw error }
    }

    private func launch(_ m: LocalModel) async throws -> URL {
        guard let bin = Self.binary else { throw LingveilError.message("Local models need an Apple silicon Mac") }
        let file = await MainActor.run { ModelStore.shared.path(m) }
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw LingveilError.message("Download \(m.name) in Settings → Models first")
        }
        port = Self.freePort()
        let p = Process()
        // Started through this app's guard (see ChildGuard), which ends the server if
        // Lingveil quits or crashes, so a model is never left holding memory.
        p.executableURL = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
        p.arguments = ["--child-guard", bin.path, "-m", file.path, "--host", "127.0.0.1", "--port", String(port),
                       "-t", String(max(2, ProcessInfo.processInfo.activeProcessorCount / 2))] + Catalog.shared.server.args
                       + (Catalog.shared.prompts[m.prompt]?.serverArgs ?? [])
        p.qualityOfService = .utility
        p.standardInput = Pipe()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        process = p
        let base = URL(string: "http://127.0.0.1:\(port)")!
        // Wait for the model to load (a few seconds the first time).
        for _ in 0..<300 {
            guard p.isRunning else { break }
            if let (_, r) = try? await URLSession.shared.data(from: base.appendingPathComponent("health")),
               (r as? HTTPURLResponse)?.statusCode == 200 { armIdleStop(); return base }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw LingveilError.message("\(m.name) could not start")
    }

    /// Ends servers left behind by an earlier run of this app.
    nonisolated static func cleanUpStale() {
        guard let bin = binary else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-f", bin.path]
        try? p.run()
        p.waitUntilExit()
    }

    func touch() { lastUse = Date() }

    nonisolated func stop() { Task { await stopNow() } }

    private func stopNow() {
        idleTask?.cancel(); idleTask = nil
        starting?.cancel(); starting = nil
        process?.terminate()
        process = nil; modelID = nil
    }

    private func armIdleStop() {
        idleTask?.cancel()
        idleTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                if Date().timeIntervalSince(lastUse) > Self.idleStop { stopNow(); return }
            }
        }
        if pressure == nil {
            let src = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global())
            src.setEventHandler { [weak self] in self?.stop() }
            src.resume()
            pressure = src
        }
    }

    private static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET),
                               sin_port: 0, sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return Int(UInt16(bigEndian: addr.sin_port))
    }
}

// MARK: - Translator

struct LocalTranslator: Translator {
    let model: LocalModel

    func translate(_ texts: [String], to target: Language) async throws -> [String] {
        guard model.supports(target) else { throw LingveilError.message("\(model.name) can't translate into \(target.name)") }
        let base = try await LlamaServer.shared.endpoint(for: model)
        // One request per line, four at a time (the server runs four slots in parallel).
        return try await withThrowingTaskGroup(of: (Int, String).self) { g in
            var out = texts
            var next = 0
            func add() {
                guard next < texts.count else { return }
                let i = next; next += 1
                g.addTask { (i, try await self.one(texts[i], to: target, base: base)) }
            }
            for _ in 0..<Catalog.shared.server.parallel { add() }
            while let (i, t) = try await g.next() { out[i] = t; add() }
            await LlamaServer.shared.touch()
            return out
        }
    }

    private func one(_ text: String, to target: Language, base: URL) async throws -> String {
        guard let p = Catalog.shared.prompts[model.prompt] else { throw LingveilError.message("Unknown prompt format \(model.prompt)") }
        let maxTokens = min(1024, text.count * 4 + 48)
        let src = Detect.language(of: text) ?? "en"
        let filled = p.template
            .replacingOccurrences(of: "{targetChinese}", with: target.chineseName)
            .replacingOccurrences(of: "{targetCode}", with: target.appleID)
            .replacingOccurrences(of: "{target}", with: target.name)
            .replacingOccurrences(of: "{sourceCode}", with: src)
            .replacingOccurrences(of: "{source}", with: Locale(identifier: "en").localizedString(forLanguageCode: src) ?? src)
            .replacingOccurrences(of: "{text}", with: text)
        var body: [String: Any] = p.params.mapValues(\.value)
        var req: URLRequest
        if p.endpoint == "completion" {
            req = URLRequest(url: base.appendingPathComponent("completion"))
            body["prompt"] = filled
            body["n_predict"] = maxTokens
            body["cache_prompt"] = true
        } else {
            req = URLRequest(url: base.appendingPathComponent("v1/chat/completions"))
            body["messages"] = [["role": "user", "content": filled]]
            body["max_tokens"] = maxTokens
            for (k, v) in Catalog.shared.server.chatExtra { body[k] = v.value }
        }
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let raw = (obj?["content"] as? String)
            ?? (((obj?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String)
            ?? text
        return Self.clean(raw)
    }

    /// Strips thinking blocks, quotes and labels that small models sometimes add.
    static func clean(_ s: String) -> String {
        var t = s
        if let r = t.range(of: "</think>") { t = String(t[r.upperBound...]) }
        t = t.replacingOccurrences(of: "<end_of_turn>", with: "")
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["Translation:", "翻译：", "译文："] where t.hasPrefix(prefix) {
            t = String(t.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return t
    }
}

/// shared/models.json, bundled in the app's resources.
struct Catalog: Decodable {
    struct Prompt: Decodable { let endpoint: String; let template: String; let params: [String: JSONValue]; let serverArgs: [String]? }
    struct Server: Decodable {
        let args: [String]; let parallel: Int; let idleStopSeconds: Int; let chatExtra: [String: JSONValue]
    }
    let languageSets: [String: Set<String>]
    let prompts: [String: Prompt]
    let server: Server
    let models: [LocalModel]

    static let shared: Catalog = {
        guard let url = Bundle.main.url(forResource: "models", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { fatalError("models.json missing from the app bundle") }
        do { return try JSONDecoder().decode(Catalog.self, from: data) }
        catch { fatalError("models.json is invalid: \(error)") }
    }()
}

/// Any JSON value, for prompt parameters passed straight through to the server.
struct JSONValue: Decodable {
    let value: Any
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { value = b }
        else if let i = try? c.decode(Int.self) { value = i }
        else if let d = try? c.decode(Double.self) { value = d }
        else if let s = try? c.decode(String.self) { value = s }
        else if let o = try? c.decode([String: JSONValue].self) { value = o.mapValues(\.value) }
        else if let a = try? c.decode([JSONValue].self) { value = a.map(\.value) }
        else { value = NSNull() }
    }
}
