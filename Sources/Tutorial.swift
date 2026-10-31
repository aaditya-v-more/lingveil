import SwiftUI

/// The tour: shown on first launch, and again from the menu or Settings → General.
@MainActor
enum Tutorial {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let host = NSHostingController(rootView: TutorialView { close() })
            let w = NSWindow(contentViewController: host)
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.setContentSize(CGSize(width: 560, height: 440))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    static func close() { window?.close(); window = nil }
}

struct TutorialView: View {
    let done: () -> Void
    @State private var page = 0
    @State private var screenOK = Capture.hasPermission
    @State private var axOK = AXText.trusted
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private struct Page { let icon: String; let title: String; let text: String; let keys: [Action] }
    private let pages: [Page] = [
        Page(icon: "character.bubble", title: "Welcome to Lingveil",
             text: "Translate anything on your screen, read anything aloud, or both. Everything works from the menu bar and a few shortcuts.", keys: []),
        Page(icon: "macwindow", title: "Translate what you see",
             text: "Press the shortcut and the screen is repainted in your language, in place. Hold ⌥ to peek at the original; click or press Esc to close.", keys: [.screen, .area]),
        Page(icon: "speaker.wave.2", title: "Read anything aloud",
             text: "Reads the selected text, or the front window from top to bottom, outlining each part as it goes. Press again or Esc to stop.", keys: [.read]),
        Page(icon: "speaker.wave.2.bubble", title: "Translate and listen",
             text: "Translates the front window (or the selection) and reads the translation aloud.", keys: [.translateRead]),
        Page(icon: "cursorarrow.rays", title: "Just one bit",
             text: "Point at a paragraph or select text to get a small card with the translation, a copy button and a speaker.", keys: [.cursor, .selection]),
        Page(icon: "play.rectangle", title: "Keep it translated",
             text: "Live mode keeps an area translated while it changes: subtitles, chats, games.", keys: [.live]),
        Page(icon: "cpu", title: "Offline and private",
             text: "In Settings → Models and Voices you can download translation models and voices that run entirely on this Mac.", keys: []),
    ]

    var body: some View {
        VStack(spacing: 0) {
            let p = pages[page]
            VStack(spacing: 14) {
                Image(systemName: p.icon)
                    .font(.system(size: 46, weight: .regular))
                    .foregroundStyle(Color.accentColor)
                    .frame(height: 64)
                Text(p.title).font(.title2.weight(.semibold))
                Text(p.text).font(.body).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)
                VStack(spacing: 8) {
                    ForEach(p.keys, id: \.self) { a in
                        HStack(spacing: 10) {
                            Text(a.title).foregroundStyle(.secondary)
                            Spacer()
                            KeyCaps(text: Prefs.shortcut(a)?.display ?? "—")
                        }
                        .frame(width: 320)
                    }
                }
                if page == 0 { permissions }
                if page == pages.count - 1 {
                    Link(destination: Support.url) {
                        Label("Lingveil is free. Support it on Ko-fi", systemImage: "heart.fill")
                    }
                    .foregroundStyle(Color(red: 1, green: 0.37, blue: 0.36))
                    .padding(.top, 8)
                }
            }
            .padding(.top, 44)
            .padding(.horizontal, 40)
            .frame(maxHeight: .infinity, alignment: .top)

            HStack {
                Button("Skip") { done() }.buttonStyle(.link).opacity(page == pages.count - 1 ? 0 : 1)
                Spacer()
                HStack(spacing: 6) {
                    ForEach(pages.indices, id: \.self) { i in
                        Circle().fill(i == page ? Color.accentColor : Color.primary.opacity(0.18)).frame(width: 6, height: 6)
                    }
                }
                Spacer()
                if page > 0 { Button("Back") { page -= 1 } }
                Button(page == pages.count - 1 ? "Start Using Lingveil" : "Next") {
                    if page == pages.count - 1 { done() } else { page += 1 }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 560, height: 440)
        .onReceive(poll) { _ in screenOK = Capture.hasPermission; axOK = AXText.trusted }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("Screen Recording", ok: screenOK, why: "to see the text on screen") {
                CGRequestScreenCaptureAccess(); Permissions.openPrivacy("Privacy_ScreenCapture")
            }
            row("Accessibility", ok: axOK, why: "for exact app text and selections (optional)") {
                AXText.requestTrust(); Permissions.openPrivacy("Privacy_Accessibility")
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .padding(.top, 6)
    }

    private func row(_ title: String, ok: Bool, why: String, grant: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle").foregroundStyle(ok ? .green : .secondary)
            Text(title).fontWeight(.medium)
            Text(why).foregroundStyle(.secondary).font(.callout)
            Spacer(minLength: 12)
            if !ok { Button("Allow…", action: grant).controlSize(.small) }
        }
        .frame(width: 440)
    }
}

struct KeyCaps: View {
    let text: String
    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(text.map(String.init).enumerated()), id: \.offset) { _, k in
                Text(k).font(.system(size: 12, weight: .medium, design: .rounded))
                    .frame(minWidth: 20, minHeight: 20)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
            }
        }
    }
}

/// One-time hints shown the first time a feature is used, when they're relevant.
@MainActor
enum Tips {
    enum Kind: String { case overlay, reading, card, live }

    private static var panel: NSPanel?

    static func show(_ k: Kind) {
        let key = "tip." + k.rawValue
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let text: String = switch k {
        case .overlay: "Tip: hold ⌥ to see the original. Right-click to copy. \(Prefs.shortcut(.read)?.display ?? "") reads it aloud."
        case .reading: "Reading aloud. Press \(Prefs.shortcut(.read)?.display ?? "the shortcut") again or Esc to stop. Voices and speed are in Settings → Voices."
        case .card: "Tip: the speaker button reads the translation aloud."
        case .live: "Live translation keeps this area translated as it changes. \(Prefs.shortcut(.live)?.display ?? "") or ⌥Esc stops it."
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { present(text) }
    }

    private static func present(_ text: String) {
        panel?.orderOut(nil)
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12.5)
        label.textColor = .white
        label.preferredMaxLayoutWidth = 380
        let icon = NSImageView(image: NSImage(systemSymbolName: "lightbulb", accessibilityDescription: nil)!)
        icon.contentTintColor = .systemYellow
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 9, left: 12, bottom: 9, right: 14)
        let fx = NSVisualEffectView()
        fx.material = .hudWindow; fx.state = .active; fx.wantsLayer = true
        fx.layer?.cornerRadius = 10; fx.layer?.masksToBounds = true
        fx.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: fx.leadingAnchor), stack.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
                                     stack.topAnchor.constraint(equalTo: fx.topAnchor), stack.bottomAnchor.constraint(equalTo: fx.bottomAnchor)])
        let size = stack.fittingSize
        let screen = NSScreen.underMouse.visibleFrame
        let p = NSPanel(contentRect: CGRect(x: screen.midX - size.width / 2, y: screen.minY + 40, width: size.width, height: size.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.level = .popUpMenu; p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = fx
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; p.animator().alphaValue = 1 }
        panel = p
        DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
            guard panel === p else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; p.animator().alphaValue = 0 }) { p.orderOut(nil) }
            panel = nil
        }
    }

    /// Lets the tips show again (Settings → General → Show Tutorial resets them).
    static func reset() {
        for k in [Kind.overlay, .reading, .card, .live] { UserDefaults.standard.removeObject(forKey: "tip." + k.rawValue) }
    }
}
