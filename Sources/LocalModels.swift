import AppKit
import CryptoKit
import NaturalLanguage

/// A translation model that runs on this Mac through the bundled llama.cpp server.
struct LocalModel: Identifiable, Hashable {
    enum Prompt { case hyMT, indexTranslate, gemma, translateGemma }

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
    let prompt: Prompt
    let speed: Int           // 1-5, measured on an M-series Mac (see BENCHMARKS.md)
    let accuracy: Int        // 1-5, measured against reference translations
    let recommended: Bool    // tested and suggested for most Macs
    let license: String
    var badge: String? = nil  // what it is best at, shown on recommended models
    var supported: Set<String>? = nil   // Google-style codes; nil = everything in Language.all

    var url: URL { URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file)")! }
    var sizeText: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    func supports(_ l: Language) -> Bool { supported?.contains(l.code) ?? true }

    static let hyMTLanguages: Set<String> = ["zh-CN", "en", "fr", "pt", "es", "ja", "tr", "ru", "ar", "ko", "th", "it", "de", "vi", "ms",
                                             "id", "tl", "hi", "zh-TW", "pl", "cs", "nl", "fa", "gu", "ur", "te", "mr", "iw", "bn", "ta", "uk"]

    /// Ordered as shown: tested recommendations first, then everything else by size.
    static let catalog: [LocalModel] = [
        LocalModel(id: "index-translate-2b", name: "Index-Translate 2B", maker: "IndexTeam",
                   summary: "A translation model on Qwen 3.5 covering 150 languages. Close to the most accurate pick, with natural everyday wording.",
                   repo: "IndexTeam/Index-Translate-2B-GGUF", file: "Index-Translate-2B.Q4_K_M.gguf",
                   sha256: "044b313d29342bd3b2c77cbb64023ca0d209bd9b3247763f9d162767ef2d746a", bytes: 1_310_000_000,
                   ramGB: 8, languages: 150, prompt: .indexTranslate, speed: 4, accuracy: 4, recommended: true, license: "Apache 2.0",
                   badge: "Best balance"),
        LocalModel(id: "hy-mt2-1.8b", name: "Hy-MT2 1.8B", maker: "Tencent",
                   summary: "Built only for translation and the quickest of the three. Wording is more literal and it slips on less common languages.",
                   repo: "tencent/Hy-MT2-1.8B-GGUF", file: "Hy-MT2-1.8B-Q4_K_M.gguf",
                   sha256: "dc5f44fcf1fa496ee7ad725982c0c8c553a4de00259b53af84c4b89fb0c06699", bytes: 1_130_000_000,
                   ramGB: 8, languages: 36, prompt: .hyMT, speed: 5, accuracy: 3, recommended: true, license: "Apache 2.0",
                   badge: "Fastest", supported: hyMTLanguages),
        LocalModel(id: "gemma-4-e2b", name: "Gemma 4 E2B", maker: "Google",
                   summary: "Google's general model. The most accurate in our tests, especially into Hindi, at a bigger download and a little less speed.",
                   repo: "ggml-org/gemma-4-E2B-it-GGUF", file: "gemma-4-E2B-it-Q4_0.gguf",
                   sha256: "8e30dff3ac4c8434c49a7036fa15564bdbb6044e42bf04550bf1a096ad7e6a52", bytes: 2_840_000_000,
                   ramGB: 8, languages: 140, prompt: .gemma, speed: 3, accuracy: 5, recommended: true, license: "Apache 2.0",
                   badge: "Most accurate"),

        LocalModel(id: "translategemma-4b", name: "TranslateGemma 4B", maker: "Google",
                   summary: "Gemma 3 tuned by the Google Translate team. Strong on long text, slower on short labels.",
                   repo: "mradermacher/translategemma-4b-it-GGUF", file: "translategemma-4b-it.Q4_K_M.gguf",
                   sha256: "81200d03e843d2ec1ece6eeafe7d13cb6e5211e1fcd336ade55790b683a08330", bytes: 2_490_000_000,
                   ramGB: 8, languages: 55, prompt: .translateGemma, speed: 3, accuracy: 3, recommended: false, license: "Gemma"),
        LocalModel(id: "gemma-4-e4b", name: "Gemma 4 E4B", maker: "Google",
                   summary: "The larger sibling of Gemma 4 E2B: more fluent and better with idioms, at about half the speed.",
                   repo: "ggml-org/gemma-4-E4B-it-GGUF", file: "gemma-4-E4B-it-Q4_0.gguf",
                   sha256: "a555b900214b477d8880e7832e0b8925e139b0159640036b09fe472b6f2097f2", bytes: 4_590_000_000,
                   ramGB: 16, languages: 140, prompt: .gemma, speed: 2, accuracy: 4, recommended: false, license: "Apache 2.0"),
        LocalModel(id: "hy-mt2-7b", name: "Hy-MT2 7B", maker: "Tencent",
                   summary: "The 7B Hy-MT2. Tencent reports it ahead of much larger open models on translation.",
                   repo: "tencent/Hy-MT2-7B-GGUF", file: "Hy-MT2-7B-Q4_K_M.gguf",
                   sha256: "9f96256500f3fc1ab4d64336b58f52a949a95ad7516b0c229476eef782f9f77b", bytes: 4_620_000_000,
                   ramGB: 16, languages: 36, prompt: .hyMT, speed: 2, accuracy: 5, recommended: false, license: "Apache 2.0",
                   supported: hyMTLanguages),
        LocalModel(id: "index-translate-9b", name: "Index-Translate 9B", maker: "IndexTeam",
                   summary: "The 9B Index-Translate, 150 languages, for Macs with memory to spare.",
                   repo: "IndexTeam/Index-Translate-9B-GGUF", file: "Index-Translate-9B.Q4_K_M.gguf",
                   sha256: "9cc6758b0007f4cbf42ea3400768cbff91ae74ef8d640e467158348426d33713", bytes: 5_780_000_000,
                   ramGB: 16, languages: 150, prompt: .indexTranslate, speed: 2, accuracy: 5, recommended: false, license: "Apache 2.0"),
        LocalModel(id: "translategemma-12b", name: "TranslateGemma 12B", maker: "Google",
                   summary: "The 12B TranslateGemma. Very accurate on documents, slow for live use.",
                   repo: "mradermacher/translategemma-12b-it-GGUF", file: "translategemma-12b-it.Q4_K_M.gguf",
                   sha256: "b7aac4b4be7ab0c49b6556c29c4467e74313df7f1e95d9f9676bb2adf0afa528", bytes: 7_300_000_000,
                   ramGB: 16, languages: 55, prompt: .translateGemma, speed: 1, accuracy: 5, recommended: false, license: "Gemma"),
        LocalModel(id: "hy-mt2-30b-a3b", name: "Hy-MT2 30B-A3B", maker: "Tencent",
                   summary: "Mixture-of-experts: only 3B of its 30B weights run per word, so it is quick for its quality, but it needs a lot of memory.",
                   repo: "tencent/Hy-MT2-30B-A3B-GGUF", file: "Hy-MT2-30B-A3B-Q4_K_M.gguf",
                   sha256: "bb44b11bb0f7cd3d1321645b41e911cd3de2e473731227fc6bf37aa18b543f88", bytes: 18_240_000_000,
                   ramGB: 32, languages: 36, prompt: .hyMT, speed: 3, accuracy: 5, recommended: false, license: "Apache 2.0",
                   supported: hyMTLanguages),
    ]

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
    static let idleStop: TimeInterval = 180

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
                       "-c", "8192", "-np", "4", "-ngl", "99", "--jinja", "-fa", "on",
                       // Small GPU work units keep window drawing smooth while it runs.
                       "-b", "512", "-ub", "256",
                       "--no-webui", "--log-disable", "-t", String(max(2, ProcessInfo.processInfo.activeProcessorCount / 2))]
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
            for _ in 0..<4 { add() }
            while let (i, t) = try await g.next() { out[i] = t; add() }
            await LlamaServer.shared.touch()
            return out
        }
    }

    private func one(_ text: String, to target: Language, base: URL) async throws -> String {
        let maxTokens = min(1024, text.count * 4 + 48)
        var req: URLRequest
        var body: [String: Any]
        switch model.prompt {
        case .translateGemma:
            // Its template expects structured content, so the prompt is built the way it would render.
            let src = Detect.language(of: text) ?? "en"
            let srcName = Locale(identifier: "en").localizedString(forLanguageCode: src) ?? src
            let prompt = "<start_of_turn>user\nYou are a professional \(srcName) (\(src)) to \(target.name) (\(target.appleID)) translator. "
                + "Your goal is to accurately convey the meaning and nuances of the original \(srcName) text while adhering to "
                + "\(target.name) grammar, vocabulary, and cultural sensitivities.\nProduce only the \(target.name) translation, "
                + "without any additional explanations or commentary. Please translate the following \(srcName) text into "
                + "\(target.name):\n\n\n\(text)<end_of_turn>\n<start_of_turn>model\n"
            req = URLRequest(url: base.appendingPathComponent("completion"))
            body = ["prompt": prompt, "n_predict": maxTokens, "temperature": 0, "cache_prompt": true]
        default:
            let content: String
            var params: [String: Any] = ["temperature": 0]
            switch model.prompt {
            case .hyMT:
                content = "Translate the following text into \(target.name). Note that you should only output the translated result without any additional explanation:\n\n\(text)"
                params = ["temperature": 0.2, "top_p": 0.6, "top_k": 20, "repeat_penalty": 1.05]
            case .indexTranslate:
                content = "请将以下文本翻译为\(target.chineseName)，直接输出翻译结果，不要进行任何解释。\n\n\(text)"
            default:
                content = "Translate the following text into \(target.name). Reply with only the translation, nothing else.\n\n\(text)"
            }
            req = URLRequest(url: base.appendingPathComponent("v1/chat/completions"))
            body = params.merging([
                "messages": [["role": "user", "content": content]],
                "max_tokens": maxTokens,
                "chat_template_kwargs": ["enable_thinking": false],
                "cache_prompt": true,
            ]) { a, _ in a }
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

extension Language {
    /// Name used in Chinese-language prompts (Index-Translate is trained on them).
    var chineseName: String {
        [
            "en": "英语", "es": "西班牙语", "fr": "法语", "de": "德语", "it": "意大利语", "pt": "葡萄牙语", "nl": "荷兰语",
            "ru": "俄语", "uk": "乌克兰语", "pl": "波兰语", "cs": "捷克语", "sv": "瑞典语", "da": "丹麦语", "nb": "挪威语",
            "fi": "芬兰语", "el": "希腊语", "tr": "土耳其语", "ro": "罗马尼亚语", "hu": "匈牙利语", "ar": "阿拉伯语",
            "iw": "希伯来语", "fa": "波斯语", "hi": "印地语", "bn": "孟加拉语", "ur": "乌尔都语", "mr": "马拉地语",
            "ta": "泰米尔语", "te": "泰卢固语", "gu": "古吉拉特语", "kn": "卡纳达语", "ml": "马拉雅拉姆语", "pa": "旁遮普语",
            "th": "泰语", "vi": "越南语", "id": "印尼语", "ms": "马来语", "tl": "菲律宾语", "zh-CN": "简体中文",
            "zh-TW": "繁体中文", "ja": "日语", "ko": "韩语",
        ][code] ?? name
    }
}
