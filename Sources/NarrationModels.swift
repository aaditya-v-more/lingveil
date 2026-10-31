import AVFoundation
import CryptoKit
import NaturalLanguage

/// An open-source narration model, run on this Mac by the small lingveil-tts helper through
/// sherpa-onnx. The catalog and ratings live in shared/voices.json (the Windows app reads it
/// too); ratings are measured by bench/voices.py and written by bench/rate.py.
struct VoiceModel: Identifiable, Hashable, Decodable {
    let id: String
    let name: String
    let maker: String
    let kind: String          // vits | kokoro | kitten | supertonic (how the helper loads it)
    let summary: String
    let url: URL
    let sha256: String
    let bytes: Int64
    let languages: [String]
    let speakers: [String: Int]
    let license: String
    let recommended: Bool
    let speed: Int            // 1-5, 0 = not rated yet
    let clarity: Int
    let tested: Bool
    let badge: String?
    let errorRate: [String: Double]?   // measured per language (lower is clearer)

    var sizeText: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    func speaks(_ language: String) -> Bool { languages.contains(VoiceModel.base(language)) }
    func speaker(for language: String) -> Int {
        speakers[language.lowercased()] ?? speakers[VoiceModel.base(language)] ?? speakers["default"] ?? 0
    }
    static func base(_ l: String) -> String { String(l.lowercased().prefix { $0 != "-" && $0 != "_" }) }
}

struct VoiceCatalog: Decodable {
    struct Runtime: Decodable { let url: URL; let sha256: String; let bytes: Int64; let keep: [String] }
    struct Rating: Decodable { let speed: Int; let clarity: Int }
    let models: [VoiceModel]
    let runtime: Runtime?
    let builtInRatings: [String: Rating]?

    private enum Keys: String, CodingKey { case models, runtime, builtInRatings }
    private struct Runtimes: Decodable { let macArm64: Runtime?; enum CodingKeys: String, CodingKey { case macArm64 = "mac-arm64" } }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: Keys.self)
        models = try c.decode([VoiceModel].self, forKey: .models)
        runtime = try c.decodeIfPresent(Runtimes.self, forKey: .runtime)?.macArm64
        builtInRatings = try c.decodeIfPresent([String: Rating].self, forKey: .builtInRatings)
    }

    static let shared: VoiceCatalog = {
        guard let url = Bundle.main.url(forResource: "voices", withExtension: "json"), let data = try? Data(contentsOf: url),
              let c = try? JSONDecoder().decode(VoiceCatalog.self, from: data) else {
            return VoiceCatalog(models: [], runtime: nil, builtInRatings: nil)
        }
        return c
    }()
    private init(models: [VoiceModel], runtime: Runtime?, builtInRatings: [String: Rating]?) {
        self.models = models; self.runtime = runtime; self.builtInRatings = builtInRatings
    }
}

// MARK: - Downloads

/// Narration models and the sherpa-onnx runtime (two libraries, ~35 MB) are downloaded on
/// demand into Application Support/Lingveil/Voices, so nothing of them ships with the app.
@MainActor
final class VoiceStore: ObservableObject {
    static let shared = VoiceStore()

    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var installed: Set<String> = []
    private var jobs: [String: Task<Void, Never>] = [:]

    nonisolated static let folder: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lingveil/Voices", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    nonisolated static var runtime: URL { folder.appendingPathComponent("runtime", isDirectory: true) }
    nonisolated static func path(_ m: VoiceModel) -> URL { folder.appendingPathComponent(m.id, isDirectory: true) }
    nonisolated static var runtimeInstalled: Bool {
        FileManager.default.fileExists(atPath: runtime.appendingPathComponent("libsherpa-onnx-c-api.dylib").path)
    }

    private init() { refresh() }

    func refresh() {
        installed = Set(VoiceCatalog.shared.models.filter { FileManager.default.fileExists(atPath: Self.path($0).path) }.map(\.id))
    }

    func download(_ m: VoiceModel) {
        guard jobs[m.id] == nil else { return }
        errors[m.id] = nil
        progress[m.id] = 0
        jobs[m.id] = Task {
            do {
                if !Self.runtimeInstalled, let r = VoiceCatalog.shared.runtime {
                    let total = Double(r.bytes + m.bytes)
                    try await fetch(r.url, sha256: r.sha256) { self.progress[m.id] = $0 * Double(r.bytes) / total } install: { dir in
                        let dest = Self.runtime
                        try? FileManager.default.removeItem(at: dest)
                        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                        for k in r.keep {
                            guard let src = Self.find(k, in: dir) else { throw LingveilError.message("The voice runtime is incomplete") }
                            try FileManager.default.moveItem(at: src, to: dest.appendingPathComponent((k as NSString).lastPathComponent))
                        }
                    }
                    try await fetch(m.url, sha256: m.sha256) { self.progress[m.id] = (Double(r.bytes) + $0 * Double(m.bytes)) / total } install: { try self.place(m, from: $0) }
                } else {
                    try await fetch(m.url, sha256: m.sha256) { self.progress[m.id] = $0 } install: { try self.place(m, from: $0) }
                }
            } catch is CancellationError {
            } catch { errors[m.id] = error.localizedDescription }
            progress[m.id] = nil
            jobs[m.id] = nil
            refresh()
        }
    }

    func cancel(_ m: VoiceModel) { jobs[m.id]?.cancel() }

    func delete(_ m: VoiceModel) {
        TTSHelper.stopAll()
        try? FileManager.default.removeItem(at: Self.path(m))
        if Prefs.voiceEngine == "model:\(m.id)" { Prefs.voiceEngine = "system" }
        refresh()
        // The runtime is only worth keeping while some model uses it.
        if installed.isEmpty { try? FileManager.default.removeItem(at: Self.runtime) }
    }

    private func place(_ m: VoiceModel, from dir: URL) throws {
        // The archive holds one folder named after the model.
        let inner = dir.appendingPathComponent(m.id)
        let src = FileManager.default.fileExists(atPath: inner.path) ? inner : dir
        try? FileManager.default.removeItem(at: Self.path(m))
        try FileManager.default.moveItem(at: src, to: Self.path(m))
    }

    nonisolated private static func find(_ relative: String, in dir: URL) -> URL? {
        let direct = dir.appendingPathComponent(relative)
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        // Release archives wrap everything in a versioned top folder.
        let tops = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return tops.map { $0.appendingPathComponent(relative) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Downloads a .tar.bz2, checks it, unpacks it into a scratch folder and hands that over.
    private func fetch(_ url: URL, sha256: String, progress: @escaping @MainActor (Double) -> Void,
                       install: (URL) throws -> Void) async throws {
        let watcher = DownloadProgress(progress)
        let (tmp, _) = try await URLSession.shared.download(from: url, delegate: watcher)
        let scratch = Self.folder.appendingPathComponent(".unpack-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch); try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try await Task.detached(priority: .utility) {
            guard ModelStore.sha256(of: tmp) == sha256 else { throw LingveilError.message("The download was damaged; try again") }
            let tar = Process()
            tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tar.arguments = ["-xjf", tmp.path, "-C", scratch.path]
            try tar.run(); tar.waitUntilExit()
            guard tar.terminationStatus == 0 else { throw LingveilError.message("Couldn't unpack the download") }
        }.value
        try Task.checkCancellation()
        try install(scratch)
    }
}

private final class DownloadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let report: @MainActor (Double) -> Void
    private var watch: NSKeyValueObservation?
    init(_ r: @escaping @MainActor (Double) -> Void) { report = r }
    func urlSession(_ s: URLSession, didCreateTask t: URLSessionTask) {
        watch = t.progress.observe(\.fractionCompleted) { [report] p, _ in
            let f = p.fractionCompleted
            Task { @MainActor in report(f) }
        }
    }
}

// MARK: - Speaking

enum NarrationModels {
    static var installed: [VoiceModel] {
        VoiceCatalog.shared.models.filter { FileManager.default.fileExists(atPath: VoiceStore.path($0).path) }
    }

    static func engine() -> VoiceEngine? {
        let id = String(Prefs.voiceEngine.dropFirst("model:".count))
        guard VoiceStore.runtimeInstalled, let m = installed.first(where: { $0.id == id }) else { return nil }
        return ModelVoices(m)
    }

    /// The model that reads `language`: the chosen one, unless another downloaded model was
    /// measured clearly better in that language (a Hindi voice next to a multilingual one);
    /// if the chosen one doesn't speak it, the clearest that does; otherwise none, and the
    /// Mac's own voice reads it.
    static func model(for language: String, preferring m: VoiceModel) -> VoiceModel? {
        let lang = VoiceModel.base(language)
        let others = installed.filter { $0.speaks(lang) && $0.id != m.id }
        if m.speaks(lang) {
            guard let mine = m.errorRate?[lang] else { return m }
            return others.filter { ($0.errorRate?[lang] ?? 1) < mine / 2 }.min { $0.errorRate![lang]! < $1.errorRate![lang]! } ?? m
        }
        return others.min { ($0.errorRate?[lang] ?? 1 - Double($0.clarity) / 10) < ($1.errorRate?[lang] ?? 1 - Double($1.clarity) / 10) }
    }
}

/// Reads with a downloaded narration model. Paragraphs are cut into sentences so the first
/// one plays while the next is being made, and the next segment is made ahead of time.
final class ModelVoices: NSObject, VoiceEngine, AVAudioPlayerDelegate {
    let model: VoiceModel
    private var player: AVAudioPlayer?
    private var done: CheckedContinuation<Void, Error>?
    private var cache: [String: Task<Data, Error>] = [:]
    private let lock = NSLock()
    private lazy var fallback = SystemVoices()

    init(_ m: VoiceModel) { model = m }

    private func language(_ s: Segment) -> String { s.language ?? Detect.language(of: s.text) ?? "en" }

    private func sentences(_ s: Segment) -> [String] {
        let t = NLTokenizer(unit: .sentence)
        t.string = s.text
        var out: [String] = []
        t.enumerateTokens(in: s.text.startIndex..<s.text.endIndex) { r, _ in
            let piece = s.text[r].trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { out.append(piece) }
            return true
        }
        return out.isEmpty ? [s.text] : out
    }

    private func audio(_ text: String, model m: VoiceModel, language: String) -> Task<Data, Error> {
        lock.withLock {
            let key = m.id + "|" + text
            if let t = cache[key] { return t }
            let speed = Prefs.speechSpeed
            let t = Task.detached(priority: .userInitiated) {
                try await TTSHelper.for(m).wav(text, speaker: m.speaker(for: language), speed: speed, language: VoiceModel.base(language))
            }
            cache[key] = t
            return t
        }
    }

    func prepare(_ s: Segment) async {
        let lang = language(s)
        guard let m = NarrationModels.model(for: lang, preferring: model), let first = sentences(s).first else { return }
        _ = audio(first, model: m, language: lang)
    }

    func speak(_ s: Segment) async throws {
        let lang = language(s)
        guard let m = NarrationModels.model(for: lang, preferring: model) else { try await fallback.speak(s); return }
        let parts = sentences(s)
        for (i, text) in parts.enumerated() {
            let data = try await audio(text, model: m, language: lang).value
            lock.withLock { _ = cache.removeValue(forKey: m.id + "|" + text) }
            try Task.checkCancellation()
            if i + 1 < parts.count { _ = audio(parts[i + 1], model: m, language: lang) }
            try await play(data)
        }
    }

    private func play(_ data: Data) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                DispatchQueue.main.async {
                    do {
                        let p = try AVAudioPlayer(data: data)
                        p.delegate = self
                        self.player = p
                        self.done = c
                        p.play()
                    } catch { c.resume(throwing: error) }
                }
            }
        } onCancel: { [weak self] in DispatchQueue.main.async { self?.stop() } }
    }

    func stop() {
        fallback.stop()
        player?.stop(); player = nil
        lock.withLock { cache.values.forEach { $0.cancel() }; cache = [:] }
        done?.resume(throwing: CancellationError()); done = nil
    }

    func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully: Bool) {
        done?.resume(); done = nil
        player = nil
    }
}

/// One running lingveil-tts per model. The helper keeps the model loaded between requests
/// and quits by itself after two idle minutes, or as soon as Lingveil goes away (its stdin
/// closes), so a model never holds memory while nothing is being read.
final class TTSHelper: @unchecked Sendable {
    nonisolated(unsafe) private static var running: [String: TTSHelper] = [:]
    private static let registry = NSLock()

    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private let queue = DispatchQueue(label: "lingveil.tts")

    static func `for`(_ m: VoiceModel) throws -> TTSHelper {
        try registry.withLock {
            if let h = running[m.id], h.process.isRunning { return h }
            let h = try TTSHelper(m)
            running[m.id] = h
            return h
        }
    }

    static func stopAll() {
        registry.withLock { running.values.forEach { $0.process.terminate() }; running = [:] }
    }

    static var binary: URL? {
        let u = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/lingveil-tts")
        return FileManager.default.isExecutableFile(atPath: u.path) ? u : nil
    }

    private init(_ m: VoiceModel) throws {
        guard let bin = Self.binary else { throw LingveilError.message("Narration models need an Apple silicon Mac") }
        let p = Process()
        p.executableURL = bin
        p.arguments = [VoiceStore.runtime.path, m.kind, VoiceStore.path(m).path,
                       String(min(4, max(2, ProcessInfo.processInfo.activeProcessorCount / 2)))]
        let i = Pipe(), o = Pipe()
        p.standardInput = i; p.standardOutput = o; p.standardError = FileHandle.nullDevice
        p.qualityOfService = .userInitiated
        try p.run()
        process = p; input = i.fileHandleForWriting; output = o.fileHandleForReading
    }

    /// Speaks `text` into a WAV file's bytes.
    func wav(_ text: String, speaker: Int, speed: Double, language: String) async throws -> Data {
        let line = text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
        return try await withCheckedThrowingContinuation { c in
            queue.async {
                do {
                    try self.input.write(contentsOf: Data("\(speaker)\t\(String(format: "%.2f", speed))\t\(language)\t\(line)\n".utf8))
                    guard let head = try self.output.read(upToCount: 8), head.count == 8 else { throw LingveilError.message("The voice stopped") }
                    let rate = head.withUnsafeBytes { $0.load(as: Int32.self) }
                    let count = head.withUnsafeBytes { $0.load(fromByteOffset: 4, as: Int32.self) }
                    guard count > 0 else { throw LingveilError.message("The voice couldn't read this") }
                    var pcm = Data(capacity: Int(count) * 4)
                    while pcm.count < Int(count) * 4 {
                        guard let more = try self.output.read(upToCount: Int(count) * 4 - pcm.count), !more.isEmpty else {
                            throw LingveilError.message("The voice stopped")
                        }
                        pcm.append(more)
                    }
                    c.resume(returning: Self.wav(floats: pcm, rate: Int(rate)))
                } catch {
                    self.process.terminate()
                    c.resume(throwing: error)
                }
            }
        }
    }

    /// 32-bit float samples into a 16-bit PCM WAV.
    private static func wav(floats: Data, rate: Int) -> Data {
        let n = floats.count / 4
        var out = Data(capacity: 44 + n * 2)
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        out.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + n * 2)); out.append(contentsOf: Array("WAVEfmt ".utf8))
        put(UInt32(16)); put(UInt16(1)); put(UInt16(1)); put(UInt32(rate)); put(UInt32(rate * 2)); put(UInt16(2)); put(UInt16(16))
        out.append(contentsOf: Array("data".utf8)); put(UInt32(n * 2))
        floats.withUnsafeBytes { raw in
            for f in raw.bindMemory(to: Float.self) { put(Int16(max(-1, min(1, f)) * 32767)) }
        }
        return out
    }
}
