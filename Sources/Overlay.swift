import AppKit

/// A translated piece of text, ready to paint.
struct Block {
    var item: TextItem
    let translation: String
    let palette: Palette
    var around = Surroundings()
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
    var blocks: [Block] = [] { didSet { prepare(); hovered = nil; shifts = []; gone = []; rebuildLayers(); redraw() } }
    /// While following the app (see Follower): how far each block's text has moved since it
    /// was laid out (points, up is positive), and blocks whose text isn't there any more.
    private var shifts: [CGFloat] = []
    private var gone = Set<Int>()
    func move(_ s: [CGFloat], hidden: Set<Int>) {
        guard s.count == blocks.count, s != shifts || hidden != gone else { return }
        let wasGone = gone
        shifts = s; gone = hidden
        // Moving is just repositioning finished layers: no text is laid out or drawn again.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, l) in layers { l.frame.origin.y = layerBase[i]! + shift(i) }
        CATransaction.commit()
        if hidden != wasGone {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.12)
            for (i, l) in layers where hidden.contains(i) != wasGone.contains(i) { fade(l, to: hidden.contains(i) ? 0 : 1) }
            CATransaction.commit()
        }
        if highlight != nil { decor.needsDisplay = true }
    }

    // Each block is its own GPU layer, painted once; scrolling only moves layers.
    private let host = Decor.Passive()
    private lazy var decor = Decor(owner: self)
    private var layers: [Int: CALayer] = [:]
    private var layerBase: [Int: CGFloat] = [:]
    private var layerKeys: [Int: String] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        host.layer = CALayer()
        host.wantsLayer = true
        host.frame = bounds; host.autoresizingMask = [.width, .height]
        addSubview(host)
        decor.frame = bounds; decor.autoresizingMask = [.width, .height]
        addSubview(decor)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func redraw() { needsDisplay = true; decor.needsDisplay = true }

    private func fade(_ l: CALayer, to v: Float) {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = l.presentation()?.opacity ?? l.opacity
        a.toValue = v
        a.duration = 0.12
        l.opacity = v
        l.add(a, forKey: "fade")
    }

    /// Layers for the current blocks. A block that is already showing at the same place
    /// with the same text keeps its layer, so re-reading the screen doesn't flicker; new
    /// ones fade in and stale ones fade out.
    private func rebuildLayers() {
        guard window != nil else { return }   // offscreen (tests): drawn in draw(_:)
        let scale = window?.backingScaleFactor ?? 2
        func key(_ text: String, _ r: CGRect) -> String { "\(text)|\(Int((r.minX / 3).rounded())),\(Int((r.minY / 3).rounded())),\(Int((r.width / 3).rounded()))" }
        var old: [String: CALayer] = [:]
        for (i, l) in layers { if let k = layerKeys[i] { old[k] = l } }
        var next: [Int: CALayer] = [:], base: [Int: CGFloat] = [:], keys: [Int: String] = [:]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for i in laid.indices where !dropped.contains(i) {
            let f = paintFrame(i)
            let k = key(blocks[i].translation, f)
            let l: CALayer
            if let reused = old.removeValue(forKey: k) {
                l = reused
                l.frame = f
                if l.opacity < 1 { fade(l, to: 1) }
            } else {
                l = CALayer()
                l.actions = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "contents": NSNull()]
                l.frame = f
                l.contentsScale = scale
                l.contents = image(i, in: f).layerContents(forContentsScale: scale)
                host.layer?.addSublayer(l)
                l.opacity = 0
                fade(l, to: 1)
            }
            next[i] = l; base[i] = f.minY; keys[i] = k
        }
        for l in old.values {
            fade(l, to: 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { l.removeFromSuperlayer() }
        }
        CATransaction.commit()
        layers = next; layerBase = base; layerKeys = keys
    }

    /// The area a block paints, with room for the card shadow.
    private func paintFrame(_ i: Int) -> CGRect {
        laid[i].fill.insetBy(dx: Prefs.style == .card ? -6 : 0, dy: Prefs.style == .card ? -6 : 0)
    }

    private func image(_ i: Int, in f: CGRect) -> NSImage {
        NSImage(size: f.size, flipped: false) { [self] _ in
            let ctx = NSGraphicsContext.current!.cgContext
            ctx.translateBy(x: -f.minX, y: -f.minY)
            paint(i, dy: 0)
            return true
        }
    }
    private func shift(_ i: Int) -> CGFloat { i < shifts.count ? shifts[i] : 0 }
    /// Each block's original text box, so a translation that needs more room only grows
    /// into space no other text occupies.
    private var baseRects: [CGRect] = []
    private var laid: [Laid] = []
    private var aligns: [NSTextAlignment] = []
    private var typicalStroke: CGFloat = 0
    var debugSizes: [(String, CGFloat?, CGFloat, NSTextAlignment)] { blocks.indices.map { (blocks[$0].item.text, blocks[$0].item.size, laid[$0].size, aligns[$0]) } }
    private var dropped = Set<Int>()   // blocks dropped because they overlap a better one
    var status: String? { didSet { updateStatus() } }
    /// Block being read aloud, outlined.
    var highlight: Int? { didSet { if highlight != oldValue { redraw() } } }
    var onClick: (() -> Void)?
    var onScroll: (() -> Void)?
    var showBorder = false { didSet { redraw() } }

    private var hovered: Int? { didSet { if hovered != oldValue { redraw() } } }
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
            self?.showOriginal = true; self?.redraw()
        }
    }

    private func index(at p: CGPoint) -> Int? {
        laid.indices.first { !dropped.contains($0) && laid[$0].fill.contains(p) }
    }

    /// Converts a global rect into this view's coordinates.
    private func local(_ r: CGRect) -> CGRect {
        guard let w = window else { return r }
        return r.offsetBy(dx: -w.frame.minX, dy: -w.frame.minY)
    }

    // MARK: layout

    struct Laid {
        var fill: CGRect          // painted background
        var textRect: CGRect      // where the text is drawn
        var text: NSAttributedString
        var size: CGFloat
    }

    /// Lays out every block: alignment from the surroundings, a fitted size per block, then
    /// one size for blocks that belong together (a column of list rows, a menu bar).
    private func prepare() {
        baseRects = blocks.map { local($0.item.rect) }
        dropped = []
        // Drop a block that mostly overlaps an earlier, better one (accessibility text wins,
        // then the larger block), so nothing is painted twice.
        let order = blocks.indices.sorted { a, b in
            let fa = blocks[a].item.fromAX, fb = blocks[b].item.fromAX
            return fa != fb ? fa : baseRects[a].width * baseRects[a].height > baseRects[b].width * baseRects[b].height
        }
        var kept: [Int] = []
        for i in order {
            let r = baseRects[i]
            if kept.contains(where: { j in
                let o = r.intersection(baseRects[j]); guard !o.isNull else { return false }
                return o.width * o.height > min(r.width * r.height, baseRects[j].width * baseRects[j].height) * 0.3
            }) { dropped.insert(i) } else { kept.append(i) }
        }
        aligns = blocks.indices.map(alignment)
        let strokes = blocks.map(\.around.stroke).filter { $0 > 0 }.sorted()
        typicalStroke = strokes.isEmpty ? 0 : strokes[strokes.count / 2]
        laid = blocks.indices.map { layout($0, cap: nil) }
        // Same font size for single-line blocks anchored on the same edge with the same
        // original size: a real localized list doesn't mix sizes.
        var groups: [String: [Int]] = [:]
        for i in blocks.indices where blocks[i].item.lines == 1 && !dropped.contains(i) {
            let r = baseRects[i], it = blocks[i].item, al = aligns[i]
            let anchor = al == .center ? r.midX : al == .right ? r.maxX : r.minX
            let base = (it.font?.pointSize ?? it.size ?? 0).rounded()
            groups["\(al.rawValue)|\(Int((anchor / 3).rounded()))|\(base)", default: []].append(i)
        }
        // The column's typical size (median) caps the larger ones; a single long item that
        // had to shrink further keeps its own size instead of shrinking the whole column.
        for members in groups.values where members.count > 1 {
            let sizes = members.map { laid[$0].size }.sorted()
            let typical = sizes[sizes.count / 2]
            for i in members where laid[i].size > typical + 0.25 { laid[i] = layout(i, cap: typical) }
        }
    }

    /// Single-line OCR text: centered when plain background stops at about the same distance
    /// on both sides (a button, a tab); right-aligned when it shares its right edge, but not
    /// its left, with a block just above or below (values in a settings row).
    private func alignment(_ i: Int) -> NSTextAlignment {
        let it = blocks[i].item, a = blocks[i].around, r = baseRects[i]
        guard !it.fromAX || it.font == nil else { return it.align }
        if it.lines > 1 { return it.align }
        // Equal space both sides: a button or tab (bounded), or a lone centered line.
        let even = abs(a.left - a.right) < max(3, (a.left + a.right) * (a.boundedLeft && a.boundedRight ? 0.3 : 0.08))
        if even && a.left + a.right > 4 && (a.boundedLeft == a.boundedRight) && a.left > 2 { return .center }
        let near = baseRects.indices.filter { j in
            j != i && abs(baseRects[j].midY - r.midY) < r.height * 4 && abs(baseRects[j].midY - r.midY) > r.height * 0.5
        }
        let sharesRight = near.contains { abs(baseRects[$0].maxX - r.maxX) < 2.5 && abs(baseRects[$0].minX - r.minX) > 6 }
        let sharesLeft = near.contains { abs(baseRects[$0].minX - r.minX) < 2.5 }
        if sharesRight && !sharesLeft { return .right }
        // Hugging a right edge with room on the left (status-bar text, trailing values).
        if a.boundedRight && a.right < it.lineHeight * 0.6 && a.left > it.lineHeight * 3 && it.align == .left { return .right }
        return it.align
    }

    private func layout(_ i: Int, cap: CGFloat?) -> Laid {
        let b = blocks[i], it = b.item, a = b.around, align = aligns[i]
        let orig = baseRects[i]
        let lh = it.lineHeight
        // Weight relative to the screen's typical stroke: absolute stroke width varies too
        // much with size and anti-aliasing to tell regular from bold on its own.
        let ratio = typicalStroke > 0 ? a.stroke / typicalStroke : 1
        let weight: NSFont.Weight = it.font != nil ? .regular : ratio >= 1.75 ? .bold : ratio >= 1.45 ? .semibold : .regular
        let base: NSFont = it.font ?? .systemFont(ofSize: it.size ?? max(8, lh * 0.8), weight: weight)
        let others = baseRects.indices.filter { $0 != i && !dropped.contains($0) }.map { baseRects[$0] }
        let single = it.lines == 1
        let para = NSMutableParagraphStyle()
        para.alignment = align
        para.lineBreakMode = single ? .byTruncatingTail : .byWordWrapping
        func attr(_ size: CGFloat) -> NSAttributedString {
            NSAttributedString(string: b.translation, attributes: [
                .font: NSFontManager.shared.convert(base, toSize: size),
                .foregroundColor: b.palette.text, .paragraphStyle: para])
        }
        let band = orig.insetBy(dx: 0, dy: orig.height * 0.25)
        let inRow = others.filter { $0.minY < band.maxY && $0.maxY > band.minY }
        // A gap shared with a neighbour in the same row is split in half, so two labels that
        // both widen (menu bars, toolbars) can't run into each other.
        let freeRight = min(a.right, inRow.filter { $0.minX >= orig.maxX - 1 }.map { ($0.minX - orig.maxX) / 2 - 1 }.min() ?? .infinity, bounds.width - orig.maxX)
        let freeLeft = min(a.left, inRow.filter { $0.maxX <= orig.minX + 1 }.map { (orig.minX - $0.maxX) / 2 - 1 }.min() ?? .infinity, orig.minX)
        var size = min(base.pointSize, cap ?? .infinity)
        var textRect = orig
        var s = attr(size)

        if single {
            func width(_ s: NSAttributedString) -> CGFloat { ceil(s.size().width) + 1 }
            // Widen into measured free background first (up to 2.5x, on the side the alignment
            // allows), and only then shrink what still doesn't fit.
            let maxGrow = max(orig.width * 1.5, lh * 4)
            let grow = max(0, min(width(s) - orig.width, maxGrow,
                                  align == .center ? 2 * max(0, min(freeLeft, freeRight)) : align == .right ? max(0, freeLeft) : max(0, freeRight)))
            textRect.size.width += grow
            if align == .center { textRect.origin.x -= grow / 2 } else if align == .right { textRect.origin.x -= grow }
            while width(s) > textRect.width, size > max(7, base.pointSize * 0.6) { size -= 0.5; s = attr(size) }
            // One line of the font's own height, centered on the original line.
            let f = NSFontManager.shared.convert(base, toSize: size)
            let lineH = ceil(f.ascender - f.descender + f.leading)
            textRect = CGRect(x: textRect.minX, y: (orig.midY - lineH / 2).rounded(), width: textRect.width, height: lineH)
        } else {
            func height(_ s: NSAttributedString) -> CGFloat {
                ceil(s.boundingRect(with: CGSize(width: textRect.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
            }
            let tolerance = orig.height * 1.06
            while height(s) > tolerance, size > max(7, base.pointSize * 0.7) { size -= 0.5; s = attr(size) }
            // Grow downward only into free background, never onto the next text below.
            let below = others.filter { $0.maxY <= orig.minY + 1 && $0.minX < orig.maxX && $0.maxX > orig.minX }.map { orig.minY - $0.maxY - 2 }.min() ?? orig.minY
            let room = max(0, min(below, a.down, orig.height * 0.5))
            while height(s) > orig.height + room, size > max(7, base.pointSize * 0.55) { size -= 0.5; s = attr(size) }
            let h = min(height(s), orig.height + room)
            // Paragraphs start at the original first line.
            // A little slack below: line fragments can need a point more than measured.
            textRect = CGRect(x: orig.minX, y: orig.maxY - h - 3, width: orig.width, height: h + 3)
        }

        // Background: the text area plus padding that stops at any border around it.
        let padX = max(2, lh * 0.18), padY = max(1, lh * 0.1)
        var fill = textRect.union(orig)
        let addLeft = min(padX, max(0, freeLeft - (orig.minX - fill.minX)))
        let addRight = min(padX, max(0, freeRight - (fill.maxX - orig.maxX)))
        fill.origin.x -= addLeft; fill.size.width += addLeft + addRight
        let addDown = min(padY, a.down + 1), addUp = min(padY, a.up + 1)
        fill.origin.y -= addDown; fill.size.height += addDown + addUp
        return Laid(fill: fill.integral, textRect: textRect, text: s, size: size)
    }

    // MARK: drawing

    override func draw(_ dirty: NSRect) {
        // In a window the blocks are layers; offscreen (tests) they are drawn here.
        guard window == nil else { return }
        for i in laid.indices where !dropped.contains(i) && !gone.contains(i) { paint(i, dy: shift(i)) }
        drawDecor()
    }

    /// Paints block `i`'s background and translation, moved up by `dy`.
    private func paint(_ i: Int, dy: CGFloat) {
        let ctx = NSGraphicsContext.current!.cgContext
        let card = Prefs.style == .card
        do {
            var l = laid[i]
            if dy != 0 { l.fill.origin.y += dy; l.textRect.origin.y += dy }
            let p = blocks[i].palette
            let radius: CGFloat = card ? 5 : 2
            let path = NSBezierPath(roundedRect: l.fill, xRadius: radius, yRadius: radius)
            ctx.saveGState()
            if card { ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 4, color: NSColor.black.withAlphaComponent(0.25).cgColor) }
            switch (card ? .none : p.axis) {
            case .vertical: NSGradient(starting: p.bottom, ending: p.top)?.draw(in: path, angle: 90)
            case .horizontal: NSGradient(starting: p.top, ending: p.bottom)?.draw(in: path, angle: 0)
            case .none: p.top.setFill(); path.fill()
            }
            ctx.restoreGState()
            if card { p.text.withAlphaComponent(0.18).setStroke(); path.lineWidth = 0.5; path.stroke() }
            l.text.draw(with: l.textRect, options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine])
        }
    }

    /// The read-aloud outline, live-mode border and original-text tooltip, above the blocks.
    fileprivate func drawDecor() {
        if let h = highlight, h < laid.count, !dropped.contains(h), !gone.contains(h) {
            let p = NSBezierPath(roundedRect: laid[h].fill.offsetBy(dx: 0, dy: shift(h)).insetBy(dx: -3, dy: -2), xRadius: 4, yRadius: 4)
            NSColor.controlAccentColor.withAlphaComponent(0.85).setStroke(); p.lineWidth = 2; p.stroke()
        }
        if showBorder {
            let b = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
            NSColor.controlAccentColor.withAlphaComponent(0.7).setStroke()
            b.lineWidth = 2; b.stroke()
        }
        if let h = hovered, showOriginal, h < laid.count { drawTooltip(blocks[h].item.text, under: laid[h].fill) }
    }

    /// A system-style tooltip with the original text, kept inside the view.
    private func drawTooltip(_ text: String, under r: CGRect) {
        let s = NSAttributedString(string: text, attributes: [.font: NSFont.toolTipsFont(ofSize: 0), .foregroundColor: NSColor.labelColor])
        let size = s.boundingRect(with: CGSize(width: 380, height: 400), options: [.usesLineFragmentOrigin]).size
        var box = CGRect(x: r.minX, y: r.minY - size.height - 10, width: ceil(size.width) + 12, height: ceil(size.height) + 8)
        if box.minY < 2 { box.origin.y = r.maxY + 4 }
        box.origin.y = min(box.minY, bounds.maxY - box.height - 2)
        box.origin.x = min(max(2, box.minX), bounds.width - box.width - 2)
        let path = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
        NSGraphicsContext.current?.cgContext.saveGState()
        NSGraphicsContext.current?.cgContext.setShadow(offset: CGSize(width: 0, height: -1), blur: 4, color: NSColor.black.withAlphaComponent(0.2).cgColor)
        NSColor.windowBackgroundColor.setFill(); path.fill()
        NSGraphicsContext.current?.cgContext.restoreGState()
        NSColor.separatorColor.setStroke(); path.lineWidth = 0.5; path.stroke()
        s.draw(with: box.insetBy(dx: 6, dy: 4), options: [.usesLineFragmentOrigin])
    }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); rebuildLayers() }

    // MARK: status

    private var hud: NSVisualEffectView?

    /// Progress and messages ("Translating…", errors) in a small HUD at the top of the
    /// overlay, wrapped and kept on screen.
    private func updateStatus() {
        hud?.removeFromSuperview(); hud = nil
        guard let text = status else { return }
        let fx = NSVisualEffectView()
        fx.material = .hudWindow
        fx.blendingMode = .withinWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 10
        fx.layer?.masksToBounds = true
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.preferredMaxLayoutWidth = min(420, bounds.width - 60)
        label.maximumNumberOfLines = 4
        let stack = NSStackView(views: [label])
        if text.hasSuffix("…") {
            let spin = NSProgressIndicator()
            spin.style = .spinning; spin.controlSize = .small; spin.startAnimation(nil)
            stack.insertArrangedSubview(spin, at: 0)
        }
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 14)
        fx.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: fx.leadingAnchor), stack.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
                                     stack.topAnchor.constraint(equalTo: fx.topAnchor), stack.bottomAnchor.constraint(equalTo: fx.bottomAnchor)])
        let size = stack.fittingSize
        let top = min(bounds.maxY - 8, bounds.maxY - (bounds.height > 300 ? 44 : 8))
        fx.frame = CGRect(x: (bounds.midX - size.width / 2).rounded(), y: max(4, top - size.height), width: size.width, height: size.height)
        addSubview(fx)
        hud = fx
    }
}

/// Draws the overlay's outline, border and tooltip above the block layers.
private final class Decor: NSView {
    final class Passive: NSView { override func hitTest(_ p: NSPoint) -> NSView? { nil } }
    unowned let owner: OverlayView
    init(owner: OverlayView) { self.owner = owner; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ p: NSPoint) -> NSView? { nil }
    override func draw(_ dirty: NSRect) { owner.drawDecor() }
}
