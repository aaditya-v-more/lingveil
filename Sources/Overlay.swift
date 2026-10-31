import AppKit

/// A translated piece of text, ready to paint.
struct Block {
    let item: TextItem
    let translation: String
    let palette: Palette
}

/// Borderless window over a screen or region that paints translations in place.
final class OverlayWindow: NSPanel {
    let view: OverlayView

    init(frame: CGRect, interactive: Bool) {
        view = OverlayView(frame: CGRect(origin: .zero, size: frame.size))
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        ignoresMouseEvents = !interactive
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        contentView = view
    }

    override var canBecomeKey: Bool { false }

    func show() {
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; animator().alphaValue = 1 }
    }

    func fadeOut(_ done: @escaping () -> Void = {}) {
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.1; animator().alphaValue = 0 }) { [weak self] in
            self?.orderOut(nil); done()
        }
    }
}

final class OverlayView: NSView {
    var blocks: [Block] = [] { didSet { layoutCache = [:]; baseRects = blocks.map { local($0.item.rect) }; hovered = nil; needsDisplay = true } }
    /// Each block's original text box, so a translation that needs more room only grows
    /// into space no other text occupies.
    private var baseRects: [CGRect] = []
    var status: String? { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    var onScroll: (() -> Void)?
    var showBorder = false { didSet { needsDisplay = true } }

    private var layoutCache: [Int: (CGRect, NSAttributedString, CGFloat)] = [:]
    private var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }
    private var hoverTimer: Timer?
    private var showOriginal = false

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .inVisibleRect], owner: self))
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func scrollWheel(with event: NSEvent) { onScroll?() }

    override func rightMouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let m = NSMenu()
        if let i = index(at: p) {
            m.addItem(withTitle: "Copy Translation", action: #selector(copyText(_:)), keyEquivalent: "").representedObject = blocks[i].translation
            m.addItem(withTitle: "Copy Original", action: #selector(copyText(_:)), keyEquivalent: "").representedObject = blocks[i].item.text
            m.addItem(.separator())
        }
        m.addItem(withTitle: "Copy All Translations", action: #selector(copyText(_:)), keyEquivalent: "").representedObject =
            blocks.sorted { $0.item.rect.maxY > $1.item.rect.maxY }.map(\.translation).joined(separator: "\n")
        m.addItem(withTitle: "Close", action: #selector(close), keyEquivalent: "")
        m.items.forEach { $0.target = self }
        NSMenu.popUpContextMenu(m, with: event, for: self)
    }

    @objc private func copyText(_ sender: NSMenuItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sender.representedObject as? String ?? "", forType: .string)
    }
    @objc private func close() { onClick?() }

    override func mouseMoved(with event: NSEvent) {
        let i = index(at: convert(event.locationInWindow, from: nil))
        hoverTimer?.invalidate()
        if i != hovered { showOriginal = false; hovered = i }
        guard i != nil else { return }
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: false) { [weak self] _ in
            self?.showOriginal = true; self?.needsDisplay = true
        }
    }

    private func index(at p: CGPoint) -> Int? {
        blocks.indices.first { layout($0).0.contains(p) }
    }

    /// Converts a global rect into this view's coordinates.
    private func local(_ r: CGRect) -> CGRect {
        guard let w = window else { return r }
        return r.offsetBy(dx: -w.frame.minX, dy: -w.frame.minY)
    }

    // MARK: drawing

    override func draw(_ dirty: NSRect) {
        let ctx = NSGraphicsContext.current!.cgContext
        let card = Prefs.style == .card
        for i in blocks.indices {
            let (r, text, _) = layout(i)
            guard r.intersects(dirty) else { continue }
            let p = blocks[i].palette
            let path = NSBezierPath(roundedRect: r, xRadius: card ? 5 : 2, yRadius: card ? 5 : 2)
            ctx.saveGState()
            if card { ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 4, color: NSColor.black.withAlphaComponent(0.25).cgColor) }
            if p.isGradient && !card {
                NSGradient(starting: p.bottom, ending: p.top)?.draw(in: path, angle: 90)
            } else {
                p.top.setFill(); path.fill()
            }
            ctx.restoreGState()
            if card { p.text.withAlphaComponent(0.18).setStroke(); path.lineWidth = 0.5; path.stroke() }
            let size = text.boundingRect(with: CGSize(width: r.width - 2, height: .greatestFiniteMagnitude),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading])
            let h = min(size.height, r.height)
            text.draw(with: CGRect(x: r.minX + 1, y: r.midY - h / 2 - 2, width: r.width - 2, height: h + 4),
                      options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine])
        }
        if showBorder {
            let b = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
            NSColor.controlAccentColor.withAlphaComponent(0.7).setStroke()
            b.lineWidth = 2; b.stroke()
        }
        if let h = hovered, showOriginal { drawTooltip(blocks[h].item.text, under: layout(h).0) }
        if let s = status { drawPill(s) }
    }

    /// Picks a font size and box so the translation fits where the original was:
    /// shrink a little, then widen single lines into free space, then shrink further.
    private func layout(_ i: Int) -> (CGRect, NSAttributedString, CGFloat) {
        if let c = layoutCache[i] { return c }
        let b = blocks[i]
        let it = b.item
        var rect = local(it.rect)
        let lh = it.lineHeight
        let base: NSFont = it.font ?? .systemFont(ofSize: it.size ?? max(8, lh * 0.8))
        let padX = max(2, lh * 0.18), padY = max(1, lh * 0.1)
        rect = rect.insetBy(dx: -padX, dy: -padY)
        let para = NSMutableParagraphStyle()
        para.alignment = it.align
        para.lineBreakMode = .byWordWrapping
        func attr(_ size: CGFloat) -> NSAttributedString {
            NSAttributedString(string: b.translation, attributes: [
                .font: NSFontManager.shared.convert(base, toSize: size),
                .foregroundColor: b.palette.text, .paragraphStyle: para])
        }
        func height(_ s: NSAttributedString, _ w: CGFloat) -> CGFloat {
            s.boundingRect(with: CGSize(width: w - 2, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        }
        let tolerance = rect.height * 1.06
        var size = base.pointSize
        let floor1 = base.pointSize * 0.76
        while size > floor1, height(attr(size), rect.width) > tolerance { size -= 0.5 }
        var s = attr(size)
        let others = baseRects.enumerated().filter { $0.offset != i }.map(\.element)
        if height(s, rect.width) > tolerance, it.lines == 1 {
            // Single line that still doesn't fit: let it grow sideways (up to 60%), but only
            // into free space and never past the edge of the screen.
            let want = s.size().width + 4
            var grow = min(want, rect.width * 1.6) - rect.width
            let band = rect.insetBy(dx: 0, dy: rect.height * 0.25)
            if it.align == .center {
                let left = others.filter { $0.maxX <= rect.minX && $0.minY < band.maxY && $0.maxY > band.minY }.map { rect.minX - $0.maxX }.min() ?? .infinity
                let right = others.filter { $0.minX >= rect.maxX && $0.minY < band.maxY && $0.maxY > band.minY }.map { $0.minX - rect.maxX }.min() ?? .infinity
                grow = min(grow, 2 * max(0, min(left, right, rect.minX, bounds.width - rect.maxX) - 2))
                rect.origin.x -= max(0, grow) / 2
            } else {
                let right = others.filter { $0.minX >= rect.maxX - 1 && $0.minY < band.maxY && $0.maxY > band.minY }.map { $0.minX - rect.maxX }.min() ?? .infinity
                grow = min(grow, max(0, min(right, bounds.width - rect.maxX) - 2))
            }
            if grow > 0 { rect.size.width += grow }
        }
        while height(s, rect.width) > tolerance, size > max(7, base.pointSize * 0.7) { size -= 0.5; s = attr(size) }
        // Still too long: run onto extra lines below, as far as the next text below allows
        // (at most half the box again); past that, shrink further and finally truncate.
        let below = others.filter { $0.maxY <= rect.minY + 1 && $0.minX < rect.maxX && $0.maxX > rect.minX }.map { rect.minY - $0.maxY }.max() ?? rect.minY
        let room = max(0, min(below - 2, rect.height * 0.5))
        while height(s, rect.width) + 2 > rect.height + room, size > max(7, base.pointSize * 0.55) { size -= 0.5; s = attr(size) }
        let need = min(height(s, rect.width) + 2, rect.height + room)
        if need > rect.height { rect.origin.y -= need - rect.height; rect.size.height = need }
        let out = (rect.integral, s, size)
        layoutCache[i] = out
        return out
    }

    private func drawTooltip(_ text: String, under r: CGRect) {
        let s = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.white])
        let size = s.boundingRect(with: CGSize(width: 380, height: 400), options: [.usesLineFragmentOrigin]).size
        var box = CGRect(x: r.minX, y: r.minY - size.height - 12, width: size.width + 12, height: size.height + 8)
        if box.minY < 0 { box.origin.y = r.maxY + 4 }
        box.origin.x = min(max(2, box.minX), bounds.width - box.width - 2)
        NSColor.black.withAlphaComponent(0.82).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        s.draw(with: box.insetBy(dx: 6, dy: 4), options: [.usesLineFragmentOrigin])
    }

    private func drawPill(_ text: String) {
        let s = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white])
        let size = s.size()
        let box = CGRect(x: bounds.midX - size.width / 2 - 12, y: bounds.maxY - size.height - 44, width: size.width + 24, height: size.height + 10)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
        s.draw(at: CGPoint(x: box.minX + 12, y: box.minY + 5))
    }
}
