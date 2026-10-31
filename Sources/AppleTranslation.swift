import SwiftUI
import Translation

/// Apple's on-device translation (the same models as the Translate app). Runs out of
/// process, works offline once a language pair is downloaded, and costs nothing.
struct AppleOnDevice: Translator {
    func translate(_ texts: [String], to target: Language) async throws -> [String] {
        let tgt = Locale.Language(identifier: target.appleID)
        guard let srcID = Detect.dominant(texts, excluding: target) else { return texts }
        let src = Locale.Language(identifier: srcID)
        let status = await LanguageAvailability().status(from: src, to: tgt)
        switch status {
        case .unsupported:
            throw LingveilError.message("On-device translation does not support \(Self.name(src)) → \(target.name)")
        case .supported:
            throw LingveilError.message("Download \(Self.name(src)) → \(target.name) in Settings → Engines to translate offline")
        default: break
        }
        if #available(macOS 26.0, *) {
            let session = TranslationSession(installedSource: src, target: tgt)
            return try await Self.run(session, texts)
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
    @State private var config: TranslationSession.Configuration?
    @State private var status = ""

    var body: some View {
        HStack {
            Button("Download for offline use") {
                config = .init(source: .init(identifier: source), target: .init(identifier: target))
                config?.invalidate()
            }
            Text(status).foregroundStyle(.secondary).font(.callout)
        }
        .translationTask(config) { session in
            do { try await session.prepareTranslation(); status = "Ready offline" }
            catch { status = error.localizedDescription }
        }
        .task(id: source + target) { await refresh() }
    }

    private func refresh() async {
        let s = await LanguageAvailability().status(from: .init(identifier: source), to: .init(identifier: target))
        status = switch s {
        case .installed: "Ready offline"
        case .supported: "Not downloaded"
        default: "Not supported on-device"
        }
    }
}
