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
    var blocks: [Block] = [] { didSet { prepare(); hovered = nil; needsDisplay = true } }
    /// Each block's original text box, so a translation that needs more room only grows
    /// into space no other text occupies.
    private var baseRects: [CGRect] = []
    private var laid: [Laid] = []
    private var aligns: [NSTextAlignment] = []
    private var typicalStroke: CGFloat = 0
    var debugSizes: [(String, CGFloat?, CGFloat, NSTextAlignment)] { blocks.indices.map { (blocks[$0].item.text, blocks[$0].item.size, laid[$0].size, aligns[$0]) } }
    private var dropped = Set<Int>()   // blocks dropped because they overlap a better one
    var status: String? { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    var onScroll: (() -> Void)?
    var showBorder = false { didSet { needsDisplay = true } }

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
        for members in groups.values where members.count > 1 {
            let smallest = members.map { laid[$0].size }.min()!
            for i in members where laid[i].size > smallest + 0.25 { laid[i] = layout(i, cap: smallest) }
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
        let weight: NSFont.Weight = it.font != nil ? .regular : ratio >= 1.5 ? .bold : ratio >= 1.3 ? .semibold : .regular
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
        let freeRight = min(a.right, inRow.filter { $0.minX >= orig.maxX - 1 }.map { $0.minX - orig.maxX - 2 }.min() ?? .infinity, bounds.width - orig.maxX)
        let freeLeft = min(a.left, inRow.filter { $0.maxX <= orig.minX + 1 }.map { orig.minX - $0.maxX - 2 }.min() ?? .infinity, orig.minX)
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
            textRect = CGRect(x: orig.minX, y: orig.maxY - h, width: orig.width, height: h)
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
        let ctx = NSGraphicsContext.current!.cgContext
        let card = Prefs.style == .card
        for i in laid.indices where !dropped.contains(i) {
            let l = laid[i]
            guard l.fill.intersects(dirty) else { continue }
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
        if showBorder {
            let b = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
            NSColor.controlAccentColor.withAlphaComponent(0.7).setStroke()
            b.lineWidth = 2; b.stroke()
        }
        if let h = hovered, showOriginal, h < laid.count { drawTooltip(blocks[h].item.text, under: laid[h].fill) }
        if let s = status { drawPill(s) }
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
