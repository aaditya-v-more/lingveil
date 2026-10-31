import AVFoundation
import AppKit
import NaturalLanguage

/// One piece of text to speak, with where it is on screen (to highlight while it's read)
/// and its language (to pick a voice that speaks it).
struct Segment {
    var text: String
    var rect: CGRect?        // global AppKit coordinates
    var language: String?    // BCP-47, e.g. "hi", "ja", "en-US"
}

/// Something that can speak a segment and returns when it has finished.
protocol VoiceEngine: AnyObject {
    func prepare(_ s: Segment) async   // optional look-ahead (fetch audio for the next segment)
    func speak(_ s: Segment) async throws
    func stop()
}

/// Reads segments one after another, highlighting each on screen. Speaking runs out of
/// process (the system speech service or a plugin's server), so the app itself stays light.
@MainActor
final class Narrator {
    static let shared = Narrator()
    private(set) var isSpeaking = false
    private var task: Task<Void, Never>?
    private var engine: VoiceEngine?
    private var stopKey: UInt32?
    var onChange: (() -> Void)?

    func read(_ segments: [Segment], highlight: @escaping @MainActor (Int?) -> Void) {
        stop()
        let segs = segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !segs.isEmpty else { return }
        let engine = Voices.engine()
        self.engine = engine
        isSpeaking = true
        StatusIcon.speaking(true)
        stopKey = HotKeys.shared.register(Shortcut(key: 53, mods: 0)) { [weak self] in self?.stop() }   // Esc
        Tips.show(.reading)
        task = Task { [weak self] in
            for (i, s) in segs.enumerated() {
                if Task.isCancelled { break }
                Debug.log("say \(i) [\(s.language ?? "-")] \(s.text.prefix(40))")
                highlight(i)
                if i + 1 < segs.count { Task { await engine.prepare(segs[i + 1]) } }
                do { try await engine.speak(s) } catch {
                    if !Task.isCancelled { Alerts.flash("Couldn't read aloud: \(error.localizedDescription)") }
                    break
                }
            }
            highlight(nil)
            self?.finish()
            Support.used()
            Support.maybeAsk()
        }
    }

    func stop() {
        task?.cancel(); task = nil
        engine?.stop(); engine = nil
        finish()
    }

    private func finish() {
        if let k = stopKey { HotKeys.shared.unregister(k); stopKey = nil }
        isSpeaking = false
        StatusIcon.speaking(false)
        Highlighter.shared.hide()
        onChange?()
    }
}

// MARK: - Engines

/// The voices built into macOS (including Premium/Enhanced voices and Personal Voice).
final class SystemVoices: NSObject, VoiceEngine, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var done: CheckedContinuation<Void, Error>?
    private var current: AVSpeechUtterance?

    override init() { super.init(); synth.delegate = self }

    func prepare(_ s: Segment) async {}

    func speak(_ s: Segment) async throws {
        let u = AVSpeechUtterance(string: s.text)
        u.voice = Voices.systemVoice(for: s.language ?? Detect.language(of: s.text) ?? "en")
        u.rate = Voices.systemRate(Prefs.speechSpeed)
        u.postUtteranceDelay = 0.08
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                DispatchQueue.main.async {
                    self.done = c
                    self.current = u
                    self.synth.speak(u)
                }
            }
        } onCancel: { [weak self] in DispatchQueue.main.async { self?.stop() } }
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        done?.resume(throwing: CancellationError()); done = nil
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        guard u === current else { return }
        done?.resume(); done = nil
    }
}

/// A voice plugin from engines.json (same format as Earmark): an HTTP endpoint that
/// returns WAV for {text, voice, rate}, or a command that writes a WAV file.
final class PluginVoices: NSObject, VoiceEngine, AVAudioPlayerDelegate {
    let config: PluginConfig
    private var player: AVAudioPlayer?
    private var done: CheckedContinuation<Void, Error>?
    private var cache: [String: Task<Data, Error>] = [:]
    private let lock = NSLock()

    init(_ c: PluginConfig) { config = c }

    private func audio(_ s: Segment) -> Task<Data, Error> {
        lock.withLock {
            if let t = cache[s.text] { return t }
            let voice = Voices.pluginVoice(config, language: s.language ?? Detect.language(of: s.text) ?? "en")
            let speed = config.speed == "player" ? 1.0 : Prefs.speechSpeed
            let t = Task { try await Plugins.synthesize(config, voice: voice, text: s.text, speed: speed) }
            cache[s.text] = t
            return t
        }
    }

    private lazy var fallback = SystemVoices()

    /// Lines in a language the plugin has no voice for are read by the Mac's own voice.
    private func covers(_ s: Segment) -> Bool {
        Voices.pluginVoice(config, language: s.language ?? Detect.language(of: s.text) ?? "en") != nil || Plugins.voices(config).isEmpty
    }

    func prepare(_ s: Segment) async { if covers(s) { _ = audio(s) } }

    func speak(_ s: Segment) async throws {
        if !covers(s) { try await fallback.speak(s); return }
        let data = try await audio(s).value
        lock.withLock { cache[s.text] = nil }
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                DispatchQueue.main.async {
                    do {
                        let p = try AVAudioPlayer(data: data)
                        p.delegate = self
                        p.enableRate = self.config.speed == "player"
                        if p.enableRate { p.rate = Float(min(2, Prefs.speechSpeed)) }
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

// MARK: - Voice choice

enum Voices {
    /// The engine the user picked: "system" or a plugin's name.
    static func engine() -> VoiceEngine {
        if Prefs.voiceEngine != "system", let p = Plugins.load().first(where: { $0.name == Prefs.voiceEngine }) {
            return PluginVoices(p)
        }
        if Prefs.voiceEngine.hasPrefix("model:"), let m = NarrationModels.engine() { return m }
        return SystemVoices()
    }

    /// The voice chosen for a language in Settings, else the best installed one
    /// (Premium, then Enhanced, then default) for that language.
    static func systemVoice(for language: String) -> AVSpeechSynthesisVoice? {
        let lang = language.lowercased()
        let base = String(lang.prefix { $0 != "-" })
        if let id = Prefs.voiceID(for: base), let v = AVSpeechSynthesisVoice(identifier: id) { return v }
        let all = AVSpeechSynthesisVoice.speechVoices().filter { v in
            let l = v.language.lowercased()
            return l == lang || l.hasPrefix(base + "-") || l == base
        }
        let preferRegion = Locale.current.region?.identifier.lowercased()
        return all.max { a, b in
            if a.quality != b.quality { return a.quality.rawValue < b.quality.rawValue }
            let ar = a.language.lowercased().hasSuffix("-" + (preferRegion ?? "")), br = b.language.lowercased().hasSuffix("-" + (preferRegion ?? ""))
            if ar != br { return !ar }
            return a.name > b.name
        } ?? AVSpeechSynthesisVoice(language: language)
    }

    /// With Apple voices, drops segments in languages that have no installed voice (they'd
    /// come out garbled in another language's voice) and says how to add one, once per language.
    @MainActor static func speakable(_ segs: [Segment]) -> [Segment] {
        guard Prefs.voiceEngine == "system" else { return segs }
        var missing = Set<String>()
        let out = segs.filter { s in
            let base = String((s.language ?? "en").prefix { $0 != "-" })
            let ok = !systemVoices(for: base).isEmpty
            if !ok { missing.insert(base) }
            return ok
        }
        if let lang = missing.first {
            let name = Locale.current.localizedString(forLanguageCode: lang) ?? lang
            Alerts.flash("No \(name) voice installed. Add one in System Settings → Accessibility → Spoken Content.")
        }
        return out
    }

    static func systemVoices(for base: String) -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().hasPrefix(base.lowercased()) }
            .sorted { $0.quality.rawValue != $1.quality.rawValue ? $0.quality.rawValue > $1.quality.rawValue : $0.name < $1.name }
    }

    /// AVSpeechUtterance's rate is 0...1 with 0.5 as normal speech; 1.0 is roughly 3x.
    static func systemRate(_ speed: Double) -> Float {
        let r = speed >= 1 ? 0.5 + (speed - 1) * 0.25 : 0.5 * speed
        return Float(min(max(r, Double(AVSpeechUtteranceMinimumSpeechRate)), Double(AVSpeechUtteranceMaximumSpeechRate)))
    }

    static func pluginVoice(_ c: PluginConfig, language: String) -> String? {
        let base = String(language.lowercased().prefix { $0 != "-" })
        if let id = Prefs.voiceID(for: "\(c.name)|\(base)") { return id }
        let voices = Plugins.voices(c)
        // Aaditya's favourite Google voice for English, otherwise the first for the language.
        if base == "en", let sfg = voices.first(where: { $0.id.hasSuffix("/sfg") }) { return sfg.id }
        return voices.first { $0.language.lowercased().hasPrefix(base) }?.id
    }
}

// MARK: - Plugins (engines.json)

struct PluginConfig: Codable {
    var name: String
    var url: String?
    var command: [String]?
    var voices: String?
    var speed: String?     // "engine": the plugin gets the speed; "player": playback is sped up
    var enabled: Bool?
    var start: [String]?   // started once if the server can't be reached
}

struct PluginVoice: Decodable, Hashable { let id: String; let name: String; let language: String; let gender: String? }

enum Plugins {
    static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Lingveil/engines.json")
    }

    static func load() -> [PluginConfig] {
        struct Root: Codable { var engines: [PluginConfig] }
        guard let data = try? Data(contentsOf: file), let root = try? JSONDecoder().decode(Root.self, from: data) else { return [] }
        return root.engines.filter { $0.enabled != false }
    }

    nonisolated(unsafe) private static var voiceCache: [String: [PluginVoice]] = [:]
    nonisolated(unsafe) private static var started = Set<String>()

    static func voices(_ c: PluginConfig) -> [PluginVoice] {
        if let v = voiceCache[c.name] { return v }
        guard let s = c.voices, let url = URL(string: s) else { return [] }
        let sem = DispatchSemaphore(value: 0)
        var out: [PluginVoice] = []
        var req = URLRequest(url: url, timeoutInterval: 3)
        req.httpMethod = "GET"
        URLSession.shared.dataTask(with: req) { data, _, _ in
            out = data.flatMap { try? JSONDecoder().decode([PluginVoice].self, from: $0) } ?? []
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 3)
        if out.isEmpty, startIfNeeded(c) { return voices(c) }
        if !out.isEmpty { voiceCache[c.name] = out }
        return out
    }

    /// Runs the plugin's start command once (e.g. Google voices' background service).
    @discardableResult
    static func startIfNeeded(_ c: PluginConfig) -> Bool {
        guard let cmd = c.start, !cmd.isEmpty, !started.contains(c.name) else { return false }
        started.insert(c.name)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cmd[0])
        p.arguments = Array(cmd.dropFirst())
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
        Thread.sleep(forTimeInterval: 1.5)
        return true
    }

    static func synthesize(_ c: PluginConfig, voice: String?, text: String, speed: Double) async throws -> Data {
        if let u = c.url, let url = URL(string: u) {
            var body: [String: Any] = ["text": text, "rate": speed]
            if let voice { body["voice"] = voice }
            var req = URLRequest(url: url, timeoutInterval: 30)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw LingveilError.message("\(c.name) returned an error") }
                return data
            } catch let e as URLError where e.code == .cannotConnectToHost {
                if startIfNeeded(c) { return try await synthesize(c, voice: voice, text: text, speed: speed) }
                throw LingveilError.message("\(c.name) isn't running")
            }
        }
        guard let cmd = c.command, !cmd.isEmpty else { throw LingveilError.message("\(c.name) needs a url or a command") }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: out) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cmd[0])
        p.arguments = cmd.dropFirst().map {
            $0.replacingOccurrences(of: "{out}", with: out.path).replacingOccurrences(of: "{voice}", with: voice ?? "")
              .replacingOccurrences(of: "{speed}", with: String(speed))
        }
        let pipe = Pipe(); p.standardInput = pipe
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run()
        pipe.fileHandleForWriting.write(Data(text.utf8)); try? pipe.fileHandleForWriting.close()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw LingveilError.message("\(c.name) exited with \(p.terminationStatus)") }
        return try Data(contentsOf: out)
    }

    /// Adds Google voices: installs google-tts-local with Homebrew, downloads Google's engine
    /// from its ChromeOS mirror, and registers the plugin (the same installer Earmark uses).
    static func installGoogle(log: @escaping @MainActor (String) -> Void) async -> Bool {
        guard let script = Bundle.main.url(forResource: "install-google-voices", withExtension: "sh") else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script.path]
        var env = ProcessInfo.processInfo.environment
        env["EARMARK_APP_NAME"] = "Lingveil"
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { h in
            let s = String(decoding: h.availableData, as: UTF8.self)
            for line in s.split(separator: "\n") where !line.isEmpty { Task { @MainActor in log(String(line)) } }
        }
        do { try p.run() } catch { return false }
        await withCheckedContinuation { c in p.terminationHandler = { _ in c.resume() } }
        pipe.fileHandleForReading.readabilityHandler = nil
        voiceCache = [:]
        return p.terminationStatus == 0
    }
}

// MARK: - On-screen highlight

/// A soft outline around the text being read, on top of everything and click-through.
@MainActor
final class Highlighter {
    static let shared = Highlighter()
    private var window: NSPanel?

    func show(_ rect: CGRect) {
        let frame = rect.insetBy(dx: -4, dy: -3)
        let w = window ?? {
            let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
            p.level = .screenSaver; p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            p.contentView = HighlightView()
            window = p
            return p
        }()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; w.animator().setFrame(frame, display: true) }
        w.orderFrontRegardless()
    }

    func hide() { window?.orderOut(nil); window = nil }

    final class HighlightView: NSView {
        override func draw(_ dirty: NSRect) {
            let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
            NSColor.controlAccentColor.withAlphaComponent(0.10).setFill(); p.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.85).setStroke(); p.lineWidth = 2; p.stroke()
        }
    }
}

// MARK: - Reading order

enum ReadingOrder {
    /// Orders text boxes the way a person reads a window: split into side-by-side columns
    /// where a clear vertical gap runs the full height (a sidebar and a content pane), but
    /// keep rows together when the two sides line up (a form's labels and values).
    static func order(_ rects: [CGRect]) -> [Int] {
        var out: [Int] = []
        cut(Array(rects.indices), rects, &out, depth: 0)
        return out
    }

    private static func cut(_ idx: [Int], _ r: [CGRect], _ out: inout [Int], depth: Int) {
        guard idx.count > 1, depth < 12 else { out += idx; return }
        // Vertical gap (columns)?
        let byX = idx.sorted { r[$0].minX < r[$1].minX }
        var reach = r[byX[0]].maxX
        for k in 1..<byX.count {
            let gap = r[byX[k]].minX - reach
            if gap > 18 {
                let left = Array(byX[..<k]), right = Array(byX[k...])
                if !rowsLineUp(left, right, r) {
                    cut(left, r, &out, depth: depth + 1); cut(right, r, &out, depth: depth + 1); return
                }
            }
            reach = max(reach, r[byX[k]].maxX)
        }
        // Horizontal gap (blocks stacked top to bottom)?
        let byY = idx.sorted { r[$0].maxY > r[$1].maxY }
        var floor = r[byY[0]].minY
        for k in 1..<byY.count {
            if floor - r[byY[k]].maxY > 2 {
                cut(Array(byY[..<k]), r, &out, depth: depth + 1); cut(Array(byY[k...]), r, &out, depth: depth + 1); return
            }
            floor = min(floor, r[byY[k]].minY)
        }
        // One row of overlapping boxes: left to right.
        out += idx.sorted { r[$0].minX < r[$1].minX }
    }

    /// True when most boxes on the left have a partner on the right at the same height.
    private static func rowsLineUp(_ l: [Int], _ rgt: [Int], _ r: [CGRect]) -> Bool {
        let partnered = l.filter { i in rgt.contains { abs(r[$0].midY - r[i].midY) < min(r[$0].height, r[i].height) * 0.6 } }.count
        return Double(partnered) >= Double(l.count) * 0.6 && l.count >= 2
    }
}
