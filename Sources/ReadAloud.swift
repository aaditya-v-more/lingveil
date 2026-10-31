import AppKit

/// Read Aloud (⌥⇧R) and Translate and Read Aloud (⌥⇧E).
///
/// What gets read, in order of preference: the translation that is showing, the selected
/// text, otherwise the front window's text in reading order. The block being read is
/// outlined on screen. The same shortcut, or Esc, stops it.
@MainActor
enum ReadAloud {
    static func read() {
        if Narrator.shared.isSpeaking { Narrator.shared.stop(); return }
        if let v = OneShot.shared.debugView, OneShot.shared.isShowing, !v.blocks.isEmpty { readOverlay(v); return }
        if let sel = AXText.selectedText() {
            Narrator.shared.read([Segment(text: sel, rect: nil, language: Detect.language(of: sel))]) { _ in }
            return
        }
        readWindow()
    }

    static func translateAndRead() {
        if Narrator.shared.isSpeaking { Narrator.shared.stop(); return }
        if let v = OneShot.shared.debugView, OneShot.shared.isShowing, !v.blocks.isEmpty { readOverlay(v); return }
        if AXText.selectedText() != nil { Bubble.shared.selection(speak: true); return }
        guard Permissions.ensureScreenCapture() else { return }
        let screen = NSScreen.underMouse
        let window = Pipeline.frontWindowFrame(of: Pipeline.frontApp).map { $0.intersection(screen.frame) }
        OneShot.shared.run(screen: screen, rect: window.flatMap { $0.isEmpty ? nil : $0 }) { _ in
            if let v = OneShot.shared.debugView { readOverlay(v) }
        }
    }

    /// Reads the translations on the overlay, in reading order, outlining each block.
    static func readOverlay(_ v: OverlayView) {
        // The title bar (window title, "Edited") isn't content.
        let titleBar = Pipeline.frontWindowFrame(of: Pipeline.frontApp).map { CGRect(x: $0.minX, y: $0.maxY - 28, width: $0.width, height: 28) }
        let blocks = v.blocks.filter { !(titleBar?.contains(CGPoint(x: $0.item.rect.midX, y: $0.item.rect.midY)) ?? false) }
        let order = ReadingOrder.order(blocks.map(\.item.rect))
        let lang = Language.named(Prefs.target).appleID
        let segs = order.map { Segment(text: blocks[$0].translation, rect: blocks[$0].item.rect, language: lang) }
        let indexInView = order.map { i in v.blocks.firstIndex { $0.item.rect == blocks[i].item.rect } }
        Narrator.shared.read(segs) { i in v.highlight = i.flatMap { indexInView[$0] } }
    }

    /// Reads the original text of the front window (or the screen under the pointer).
    static func readWindow() {
        guard Permissions.ensureScreenCapture() else { return }
        let app = Pipeline.frontApp
        let screen = NSScreen.underMouse
        let window = Pipeline.frontWindowFrame(of: app).map { $0.intersection(screen.frame) }
        StatusIcon.busy(true)
        Task {
            defer { StatusIcon.busy(false) }
            guard let snap = try? await Capture.snapshot(screen, rect: window.flatMap { $0.isEmpty ? nil : $0 }) else { return }
            // Skip the title bar (window title, "Edited"): it isn't content.
            let titleBar = window.map { CGRect(x: $0.minX, y: $0.maxY - 28, width: $0.width, height: 28) }
            let items = await Pipeline.items(in: snap, app: app).filter {
                $0.hasLetters && !$0.isLiteral && !(titleBar?.contains(CGPoint(x: $0.rect.midX, y: $0.rect.midY)) ?? false)
            }
            guard !items.isEmpty else { Alerts.flash("No text to read here"); return }
            let order = ReadingOrder.order(items.map(\.rect))
            var segs = order.map { Segment(text: items[$0].text, rect: items[$0].rect, language: Detect.language(of: items[$0].text)) }
            segs = Voices.speakable(segs)
            Narrator.shared.read(segs) { i in
                if let i, let r = segs[i].rect { Highlighter.shared.show(r) } else { Highlighter.shared.hide() }
            }
        }
    }
}

/// Short-lived message near the top of the screen, for things that need no action.
extension Alerts {
    private static var toast: NSPanel?

    static func flash(_ text: String) {
        toast?.orderOut(nil)
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        let fx = NSVisualEffectView()
        fx.material = .hudWindow; fx.state = .active; fx.wantsLayer = true
        fx.layer?.cornerRadius = 10; fx.layer?.masksToBounds = true
        fx.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: fx.centerXAnchor), label.centerYAnchor.constraint(equalTo: fx.centerYAnchor)])
        let size = CGSize(width: label.intrinsicContentSize.width + 32, height: 34)
        let screen = NSScreen.underMouse.visibleFrame
        let p = NSPanel(contentRect: CGRect(x: screen.midX - size.width / 2, y: screen.maxY - size.height - 24, width: size.width, height: size.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.level = .popUpMenu; p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = fx
        p.orderFrontRegardless()
        toast = p
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { if toast === p { p.orderOut(nil); toast = nil } }
    }
}
