import SwiftUI
import Translation
import NaturalLanguage

/// Apple's on-device translation (the same models as the Translate app). Runs out of
/// process, works offline once a language pair is downloaded, and costs nothing.
struct AppleOnDevice: Translator {
    /// Lines are grouped by their own language, since one screen often mixes several
    /// (an English app showing Japanese and Spanish messages). Short lines that can't be
    /// identified go with the screen's main language.
    func translate(_ texts: [String], to target: Language) async throws -> [String] {
        let tgt = Locale.Language(identifier: target.appleID)
        guard let main = Detect.dominant(texts, excluding: target) else { return texts }
        var groups: [String: [Int]] = [:]
        for (i, t) in texts.enumerated() {
            let r = NLLanguageRecognizer()
            r.processString(t)
            let best = r.languageHypotheses(withMaximum: 1).first
            let lang = (best.map { $0.value > 0.6 && t.count >= 3 } ?? false) ? best!.key.rawValue : main
            if lang == target.appleID { continue }
            groups[lang, default: []].append(i)
        }
        var out = texts
        var lastError: Error?
        for (lang, idx) in groups.sorted(by: { $0.value.count > $1.value.count }) {
            do {
                let done = try await translate(idx.map { texts[$0] }, from: Locale.Language(identifier: lang), to: tgt, target)
                for (i, t) in zip(idx, done) { out[i] = t }
            } catch { lastError = error }
        }
        if out == texts, let lastError { throw lastError }
        return out
    }

    private func translate(_ texts: [String], from src: Locale.Language, to tgt: Locale.Language, _ target: Language) async throws -> [String] {
        var fast = false
        if #available(macOS 26.4, *), Prefs.appleFast,
           await LanguageAvailability(preferredStrategy: .lowLatency).status(from: src, to: tgt) == .installed { fast = true }
        switch await LanguageAvailability().status(from: src, to: tgt) {
        case .unsupported:
            throw LingveilError.message("On-device translation does not support \(Self.name(src)) → \(target.name)")
        case .supported:
            throw LingveilError.message("Download \(Self.name(src)) → \(target.name) in Settings → Models to translate offline")
        default: break
        }
        if #available(macOS 26.4, *), fast {
            return try await Self.run(TranslationSession(installedSource: src, target: tgt, preferredStrategy: .lowLatency), texts)
        }
        if #available(macOS 26.0, *) {
            return try await Self.run(TranslationSession(installedSource: src, target: tgt), texts)
        }
        return try await AppleBridge.shared.translate(texts, from: src, to: tgt)
    }

    static func run(_ session: TranslationSession, _ texts: [String]) async throws -> [String] {
        let reqs = texts.enumerated().map { TranslationSession.Request(sourceText: $1, clientIdentifier: String($0)) }
        var out = texts
        for r in try await session.translations(from: reqs) {
            if let i = r.clientIdentifier.flatMap(Int.init) { out[i] = r.targetText }
        }
        return out
    }

    static func name(_ l: Locale.Language) -> String {
        Locale.current.localizedString(forIdentifier: l.minimalIdentifier) ?? l.minimalIdentifier
    }
}

/// macOS 15 only hands out sessions through SwiftUI's `.translationTask`, so a tiny
/// invisible window hosts one and serves queued jobs for as long as the pair stays the same.
@MainActor
final class AppleBridge: ObservableObject {
    static let shared = AppleBridge()
    @Published var config: TranslationSession.Configuration?
    private var jobs: [Job] = []
    private var kick: AsyncStream<Void>.Continuation?
    private var window: NSWindow?

    struct Job {
        let src: Locale.Language, tgt: Locale.Language, texts: [String]
        let cont: CheckedContinuation<[String], Error>
    }

    func translate(_ texts: [String], from src: Locale.Language, to tgt: Locale.Language) async throws -> [String] {
        host()
        return try await withCheckedThrowingContinuation { c in
            jobs.append(Job(src: src, tgt: tgt, texts: texts, cont: c))
            pump()
        }
    }

    private func pump() {
        guard let j = jobs.first else { return }
        if config?.source == j.src && config?.target == j.tgt { kick?.yield() }
        else { config = .init(source: j.src, target: j.tgt) }
    }

    func serve(_ session: TranslationSession) async {
        let (stream, cont) = AsyncStream<Void>.makeStream()
        kick = cont
        cont.yield()
        for await _ in stream {
            while let i = jobs.firstIndex(where: { $0.src == session.sourceLanguage && $0.tgt == session.targetLanguage }) {
                let j = jobs.remove(at: i)
                do { j.cont.resume(returning: try await AppleOnDevice.run(session, j.texts)) }
                catch { j.cont.resume(throwing: error) }
            }
            if !jobs.isEmpty { pump() }
        }
    }

    private func host() {
        guard window == nil else { return }
        let w = NSWindow(contentRect: NSRect(x: -10, y: -10, width: 1, height: 1), styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.alphaValue = 0
        w.ignoresMouseEvents = true
        w.contentView = NSHostingView(rootView: BridgeView(bridge: self))
        w.orderFrontRegardless()
        window = w
    }

    struct BridgeView: View {
        @ObservedObject var bridge: AppleBridge
        var body: some View {
            Color.clear.frame(width: 1, height: 1)
                .translationTask(bridge.config) { session in await bridge.serve(session) }
        }
    }
}

/// Settings row that downloads a language pair through the system's own download sheet.
struct LanguageDownloadButton: View {
    let source: String
    let target: String
    var fast = false
    @State private var config: TranslationSession.Configuration?
    @State private var status = ""

    var body: some View {
        HStack {
            Button("Download for offline use") {
                if #available(macOS 26.4, *), fast {
                    config = .init(source: .init(identifier: source), target: .init(identifier: target), preferredStrategy: .lowLatency)
                } else {
                    config = .init(source: .init(identifier: source), target: .init(identifier: target))
                }
                config?.invalidate()
            }
            Text(status).foregroundStyle(.secondary).font(.callout)
        }
        .translationTask(config) { session in
            do { try await session.prepareTranslation(); status = "Ready offline" }
            catch { status = error.localizedDescription }
        }
        .task(id: source + target + String(fast)) { await refresh() }
    }

    private func refresh() async {
        var availability = LanguageAvailability()
        if #available(macOS 26.4, *), fast { availability = LanguageAvailability(preferredStrategy: .lowLatency) }
        let s = await availability.status(from: .init(identifier: source), to: .init(identifier: target))
        status = switch s {
        case .installed: "Ready offline"
        case .supported: "Not downloaded"
        default: "Not supported on-device"
        }
    }
}
