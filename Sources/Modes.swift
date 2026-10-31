import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit

/// One-shot translation of the screen (or a picked area): the overlay stays until a
/// click, scroll, Esc, app switch, or the same shortcut again.
@MainActor
final class OneShot {
    static let shared = OneShot()
    private var window: OverlayWindow?
    private var escKey: UInt32?
    private var peek: Timer?
    private var appObserver: NSObjectProtocol?
    private var task: Task<Void, Never>?

    var isShowing: Bool { window != nil }
    var debugView: OverlayView? { window?.view }

    func toggleScreen() {
        if isShowing { dismiss(); return }
        run(screen: .underMouse, rect: nil)
    }

    func area() {
        dismiss()
        Task {
            guard let (screen, rect) = await RegionPicker.pick() else { return }
            run(screen: screen, rect: rect)
        }
    }

    func run(screen: NSScreen, rect: CGRect?) {
        guard Permissions.ensureScreenCapture() else { return }
        dismiss()
        Translation.preconnect()
        let app = Pipeline.frontApp
        let w = OverlayWindow(frame: rect ?? screen.frame, interactive: true)
        w.view.onClick = { [weak self] in self?.dismiss() }
        w.view.onScroll = { [weak self] in self?.dismiss() }
        w.show()
        window = w
        armDismissal()
        StatusIcon.busy(true)
        let target = Language.named(Prefs.target)
        task = Task {
            let slow = Task { try? await Task.sleep(for: .milliseconds(350)); if !Task.isCancelled { w.view.status = "Translating…" } }
            defer { slow.cancel(); StatusIcon.busy(false) }
            do {
                let tc = Date()
                let snap = try await Capture.snapshot(screen, rect: rect)
                let captureMs = Date().timeIntervalSince(tc) * 1000
                let items = await Pipeline.items(in: snap, app: app)
                for it in items { Debug.log("item \(it.fromAX ? "AX " : "OCR") \(Int(it.rect.minX)),\(Int(it.rect.minY)) \(Int(it.rect.width))x\(Int(it.rect.height)) \(it.text.prefix(50))") }
                let blocks = try await Pipeline.blocks(for: items, in: snap, to: target, focus: Pipeline.frontWindowFrame(of: app)) { partial in
                    guard self.window === w else { return }
                    slow.cancel(); w.view.status = nil; w.view.blocks = partial
                }
                Pipeline.timings = String(format: "capture %.0f ms, ", captureMs) + Pipeline.timings
                guard !Task.isCancelled, window === w else { return }
                slow.cancel()
                w.view.status = nil
                w.view.blocks = blocks
                if blocks.isEmpty { flash(w, "Nothing to translate into \(target.name)") }
            } catch {
                guard window === w else { return }
                slow.cancel()
                flash(w, error.localizedDescription)
            }
        }
    }

    private func flash(_ w: OverlayWindow, _ msg: String) {
        w.view.status = msg
        Task { try? await Task.sleep(for: .seconds(2)); if window === w { dismiss() } }
    }

    private func armDismissal() {
        escKey = HotKeys.shared.register(Shortcut(key: UInt32(kVK_Escape), mods: 0)) { [weak self] in self?.dismiss() }
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if a?.processIdentifier != getpid() { MainActor.assumeIsolated { self?.dismiss() } }
        }
        // Hold ⌥ to peek at the original.
        peek = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let w = self?.window else { return }
                let peeking = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask) == .option
                w.contentView?.alphaValue = peeking ? 0 : 1
            }
        }
    }

    func dismiss() {
        task?.cancel(); task = nil
        if let k = escKey { HotKeys.shared.unregister(k); escKey = nil }
        if let o = appObserver { NSWorkspace.shared.notificationCenter.removeObserver(o); appObserver = nil }
        peek?.invalidate(); peek = nil
        if let w = window { window = nil; w.fadeOut { Memory.relieve() } }
    }
}

// MARK: - Region picker

@MainActor
enum RegionPicker {
    private final class PickerWindow: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private final class PickerView: NSView {
        var start: CGPoint?
        var current: CGRect?
        var done: ((CGRect?) -> Void)?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var acceptsFirstResponder: Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
        override func mouseDown(with e: NSEvent) { start = convert(e.locationInWindow, from: nil) }
        override func mouseDragged(with e: NSEvent) {
            guard let s = start else { return }
            let p = convert(e.locationInWindow, from: nil)
            current = CGRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(p.x - s.x), height: abs(p.y - s.y))
            needsDisplay = true
        }
        override func mouseUp(with e: NSEvent) {
            guard let r = current, r.width > 8, r.height > 8 else { done?(nil); return }
            done?(r.offsetBy(dx: window!.frame.minX, dy: window!.frame.minY))
        }
        override func keyDown(with e: NSEvent) { if e.keyCode == UInt16(kVK_Escape) { done?(nil) } }
        override func rightMouseDown(with event: NSEvent) { done?(nil) }
        override func draw(_ dirty: NSRect) {
            NSColor.black.withAlphaComponent(0.22).setFill()
            bounds.fill()
            if let r = current {
                NSColor.clear.setFill(); r.fill(using: .copy)
                NSColor.white.setStroke()
                let p = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5)); p.lineWidth = 1; p.stroke()
            } else {
                let s = NSAttributedString(string: "Drag over the text to translate · Esc to cancel",
                                           attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white])
                let sz = s.size()
                s.draw(at: CGPoint(x: bounds.midX - sz.width / 2, y: bounds.maxY - 90))
            }
        }
    }

    static func pick() async -> (NSScreen, CGRect)? {
        if let r = Debug.rect {
            Debug.rect = nil
            return (NSScreen.screens.first { $0.frame.intersects(r) } ?? .underMouse, r)
        }
        let screen = NSScreen.underMouse
        let w = PickerWindow(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let v = PickerView(frame: CGRect(origin: .zero, size: screen.frame.size))
        w.contentView = v
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(v)
        let rect: CGRect? = await withCheckedContinuation { c in
            v.done = { r in v.done = nil; c.resume(returning: r) }
        }
        w.orderOut(nil)
        NSApp.hide(nil)   // hand focus back to the app being translated
        return rect.map { (screen, $0) }
    }
}

// MARK: - Live

/// Keeps an area translated while it changes (video subtitles, chats, games). Uses a
/// ScreenCaptureKit stream, which only delivers frames when pixels change, so an idle
/// screen costs nothing.
@MainActor
final class Live: NSObject, SCStreamOutput, SCStreamDelegate {
    static let shared = Live()
    private var stream: SCStream?
    private var window: OverlayWindow?
    private var screen: NSScreen?
    private var area: CGRect = .zero
    private var pending: PixelBuffer?
    private var working = false
    private var lastChange = Date.distantPast
    private var stopKey: UInt32?
    private let queue = DispatchQueue(label: "lingveil.live", qos: .userInitiated)

    var isRunning: Bool { stream != nil }
    var debugView: OverlayView? { window?.view }

    func toggle() {
        if isRunning { stop(); return }
        OneShot.shared.dismiss()
        Task {
            guard Permissions.ensureScreenCapture(), let (s, r) = await RegionPicker.pick() else { return }
            await start(screen: s, rect: r)
        }
    }

    func start(screen: NSScreen, rect: CGRect) async {
        self.screen = screen; area = rect
        // The overlay goes up first so the capture filter can exclude it.
        let w = OverlayWindow(frame: rect, interactive: false)
        w.view.showBorder = true
        w.show()
        window = w
        do {
            let (filter, _) = try await Capture.filter(for: screen)
            let cfg = SCStreamConfiguration()
            cfg.sourceRect = Capture.localRect(rect, on: screen)
            cfg.width = Int(rect.width * screen.backingScaleFactor)
            cfg.height = Int(rect.height * screen.backingScaleFactor)
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 4)
            cfg.queueDepth = 3
            cfg.showsCursor = false
            cfg.pixelFormat = kCVPixelFormatType_32BGRA
            let s = SCStream(filter: filter, configuration: cfg, delegate: self)
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await s.startCapture()
            Debug.log("live started \(rect)")
            stream = s
        } catch {
            window?.orderOut(nil); window = nil
            Alerts.show("Live translation could not start", error.localizedDescription); return
        }
        stopKey = HotKeys.shared.register(Shortcut(key: UInt32(kVK_Escape), mods: UInt32(optionKey))) { [weak self] in self?.stop() }
        StatusIcon.live(true)
    }

    func stop() {
        if let k = stopKey { HotKeys.shared.unregister(k); stopKey = nil }
        let s = stream; stream = nil
        Task { try? await s?.stopCapture() }
        window?.fadeOut { Memory.relieve() }; window = nil
        pending = nil
        lastPrint = []
        StatusIcon.live(false)
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = sb.imageBuffer else { return }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), row = CVPixelBufferGetBytesPerRow(pb)
        guard let src = CVPixelBufferGetBaseAddress(pb) else { return }
        // ScreenCaptureKit can mark unchanged frames complete, so compare a coarse
        // brightness fingerprint and only copy and translate when the picture changed.
        let print = Self.fingerprint(src, w, h, row)
        guard Self.differs(print, lastPrint) else { return }
        lastPrint = print
        guard let px = PixelBuffer(width: w, height: h) else { return }
        for y in 0..<h { memcpy(px.base + y * px.bytesPerRow, src + y * row, w * 4) }
        Task { @MainActor in self.frameChanged(px) }
    }

    private nonisolated(unsafe) var lastPrint: [UInt8] = []

    nonisolated static func fingerprint(_ base: UnsafeMutableRawPointer, _ w: Int, _ h: Int, _ row: Int) -> [UInt8] {
        let n = 64
        var out = [UInt8](repeating: 0, count: n * n)
        let p = base.assumingMemoryBound(to: UInt8.self)
        for gy in 0..<n {
            let y = min(h - 1, gy * h / n + h / (2 * n))
            for gx in 0..<n {
                let o = y * row + min(w - 1, gx * w / n + w / (2 * n)) * 4
                out[gy * n + gx] = UInt8((Int(p[o]) + 2 * Int(p[o + 1]) + Int(p[o + 2])) / 4)
            }
        }
        return out
    }

    nonisolated static func differs(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return true }
        var changed = 0
        for i in a.indices where abs(Int(a[i]) - Int(b[i])) > 12 { changed += 1 }
        return changed > 2
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in self.stop() }
    }

    private func frameChanged(_ px: PixelBuffer) {
        pending = px
        lastChange = Date()
        guard !working else { return }
        working = true
        Task {
            // Let scrolling / animation settle briefly before reading the text.
            while Date().timeIntervalSince(lastChange) < 0.25 { try? await Task.sleep(for: .milliseconds(80)) }
            while let px = pending, let screen, isRunning {
                pending = nil
                let snap = Snapshot(pixels: px, frame: area, scale: screen.backingScaleFactor)
                let items = await Pipeline.items(in: snap, app: Pipeline.frontApp)
                Debug.log("live items \(items.count)")
                do {
                    let blocks = try await Pipeline.blocks(for: items, in: snap, to: Language.named(Prefs.target))
                    Debug.log("live blocks \(blocks.count)")
                    if isRunning { window?.view.blocks = blocks }
                } catch { Debug.log("live error \(error.localizedDescription)") }
            }
            working = false
        }
    }
}

// MARK: - Bubble (pointer / selection)

/// A small floating card with a translation, for the text under the pointer or a selection.
@MainActor
final class Bubble {
    static let shared = Bubble()
    private var panel: NSPanel?
    private var monitor: Any?
    private var escKey: UInt32?
    private var lastText = ""
    private(set) var debugText: String?

    func underPointer(quiet: Bool = false) {
        let p = Debug.point ?? NSEvent.mouseLocation
        Debug.point = nil
        if !quiet { close() }
        Task {
            var found: (String, CGRect?)?
            if Prefs.useAccessibility, AXText.trusted, let el = AXText.element(at: p) {
                var pid: pid_t = 0
                AXUIElementGetPid(el, &pid)
                if pid != getpid() { found = AXText.paragraph(in: el, at: p) ?? AXText.text(of: el) }
            }
            if found == nil {
                guard Permissions.ensureScreenCapture() else { return }
                let screen = NSScreen.underMouse
                let area = CGRect(x: p.x - 450, y: p.y - 140, width: 900, height: 280).intersection(screen.frame)
                guard let snap = try? await Capture.snapshot(screen, rect: area) else { return }
                let items = await OCR.items(in: snap)
                let hit = items.first { $0.rect.insetBy(dx: -4, dy: -4).contains(p) }
                    ?? items.min { dist($0.rect, p) < dist($1.rect, p) }
                if let hit { found = (hit.text, hit.rect) }
            }
            guard let (text, rect) = found else { if !quiet { show("No text under the pointer", nil, near: p) }; return }
            if quiet && text == lastText && panel != nil { return }
            await translateAndShow(text, near: rect.map { CGPoint(x: $0.minX, y: $0.minY) } ?? p)
        }
    }

    func selection() {
        guard let text = AXText.selectedText() else {
            if !AXText.trusted { Permissions.ensureAccessibility(); return }
            show("Select some text first", nil, near: NSEvent.mouseLocation); return
        }
        Task { await translateAndShow(text, near: NSEvent.mouseLocation) }
    }

    private func translateAndShow(_ text: String, near p: CGPoint) async {
        lastText = text
        let target = Language.named(Prefs.target)
        do {
            let t = try await Translation.translate([text], to: target).first ?? text
            show(t, text, near: p)
        } catch { show(error.localizedDescription, nil, near: p) }
    }

    private func dist(_ r: CGRect, _ p: CGPoint) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return dx * dx + dy * dy
    }

    func show(_ translation: String, _ original: String?, near p: CGPoint) {
        close()
        debugText = (original.map { $0 + " => " } ?? "") + translation
        Debug.log("card \(debugText ?? "")")
        let tf = NSTextField(wrappingLabelWithString: translation)
        tf.font = .systemFont(ofSize: 14)
        tf.isSelectable = true
        tf.preferredMaxLayoutWidth = 380
        tf.maximumNumberOfLines = 14
        tf.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [tf])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        if let original, original != translation {
            let o = NSTextField(wrappingLabelWithString: original)
            o.font = .systemFont(ofSize: 11)
            o.textColor = .secondaryLabelColor
            o.preferredMaxLayoutWidth = 380
            o.maximumNumberOfLines = 4
            let copy = NSButton(image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy translation")!,
                                target: self, action: #selector(copy(_:)))
            copy.isBordered = false
            copy.contentTintColor = .secondaryLabelColor
            copy.toolTip = "Copy translation"
            copy.identifier = NSUserInterfaceItemIdentifier(translation)
            let row = NSStackView(views: [o, NSView(), copy])
            row.alignment = .lastBaseline
            row.setHuggingPriority(.defaultLow, for: .horizontal)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }
        let fx = NSVisualEffectView()
        fx.material = .popover
        fx.state = .active
        // A mask (not a layer radius) gives the blur, the corners and the window shadow
        // the same rounded shape.
        fx.maskImage = NSImage(size: CGSize(width: 21, height: 21), flipped: false) { r in
            NSColor.black.setFill(); NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10).fill(); return true
        }
        fx.maskImage?.capInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        fx.maskImage?.resizingMode = .stretch
        fx.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: fx.leadingAnchor), stack.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
                                     stack.topAnchor.constraint(equalTo: fx.topAnchor), stack.bottomAnchor.constraint(equalTo: fx.bottomAnchor)])
        let size = stack.fittingSize
        let screen = NSScreen.underMouse.visibleFrame
        var origin = CGPoint(x: p.x + 4, y: p.y - size.height - 12)
        if origin.y < screen.minY { origin.y = p.y + 24 }
        origin.y = min(origin.y, screen.maxY - size.height - 4)
        origin.x = min(max(screen.minX + 4, origin.x), screen.maxX - size.width - 4)
        let w = NSPanel(contentRect: CGRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.level = .popUpMenu
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.contentView = fx
        w.orderFrontRegardless()
        panel = w
        escKey = HotKeys.shared.register(Shortcut(key: UInt32(kVK_Escape), mods: 0)) { [weak self] in self?.close() }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    @objc private func copy(_ b: NSButton) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(b.identifier?.rawValue ?? "", forType: .string)
        close()
    }

    func close() {
        debugText = nil
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        if let k = escKey { HotKeys.shared.unregister(k); escKey = nil }
        if panel != nil { panel?.orderOut(nil); panel = nil; Memory.relieve() }
    }
}

/// Optional: hold ⌥ and rest the pointer on text to see it translated.
@MainActor
final class HoverWatcher {
    static let shared = HoverWatcher()
    private var timer: Timer?
    private var lastPoint = CGPoint.zero
    private var still = 0

    func update() {
        timer?.invalidate(); timer = nil
        guard Prefs.hoverWithOption else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask) == .option, !OneShot.shared.isShowing else { still = 0; return }
        let p = NSEvent.mouseLocation
        if hypot(p.x - lastPoint.x, p.y - lastPoint.y) > 3 { lastPoint = p; still = 0; return }
        still += 1
        if still == 3 { Bubble.shared.underPointer(quiet: true) }
    }
}

enum Memory {
    /// Screen captures pass through tens of MB of buffers; once a translation is closed,
    /// hand the freed pages back to the system instead of keeping them for reuse.
    static func relieve() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
            malloc_zone_pressure_relief(nil, 0)
        }
    }
}
