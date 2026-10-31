import AppKit

/// Colors sampled from the screenshot around and inside a piece of text, so the
/// translation can be painted in the same colors as the original.
struct Palette {
    enum Axis { case none, vertical, horizontal }
    var top: NSColor        // background at the top (or left, for horizontal)
    var bottom: NSColor     // background at the bottom (or right)
    var text: NSColor
    var axis: Axis = .none
    var background: RGB = RGB(1, 1, 1)
    var ink: RGB = RGB(0, 0, 0)
    var isGradient: Bool { axis != .none }

    static let fallback = Palette(top: .windowBackgroundColor, bottom: .windowBackgroundColor, text: .labelColor)

    /// `rect` is the text's rect in image pixels. Background = the most common color in a
    /// thin ring just outside the letters; text = the inner pixels farthest from it.
    static func sample(_ px: PixelBuffer, rect: CGRect) -> Palette {
        let ring = max(1, min(3, rect.height * 0.08)).rounded()
        let outer = rect.insetBy(dx: -ring, dy: -ring).integral
            .intersection(CGRect(x: 0, y: 0, width: px.width, height: px.height))
        guard outer.width >= 4, outer.height >= 4 else { return .fallback }
        let ox = Int(outer.minX), oy = Int(outer.minY), w = Int(outer.width), h = Int(outer.height)
        let inner = rect.offsetBy(dx: -outer.minX, dy: -outer.minY)
        let ix0 = Int(inner.minX), iy0 = Int(inner.minY), ix1 = Int(inner.maxX), iy1 = Int(inner.maxY)
        var topPx: [RGB] = [], botPx: [RGB] = [], leftPx: [RGB] = [], rightPx: [RGB] = [], insidePx: [(RGB, Int)] = []
        let step = max(1, (w * h) / 40_000)   // cap work on huge blocks
        var i = 0
        for y in 0..<h {
            for x in 0..<w {
                i += 1
                if i % step != 0 { continue }
                let c = px.rgb(ox + x, oy + y)
                if x >= ix0 && x < ix1 && y >= iy0 && y < iy1 { insidePx.append((c, y)) }
                else if y < iy0 { topPx.append(c) }
                else if y >= iy1 { botPx.append(c) }
                else if x < ix0 { leftPx.append(c) }
                else { rightPx.append(c) }
            }
        }
        let ringPx = topPx + botPx + leftPx + rightPx
        guard !ringPx.isEmpty else { return .fallback }
        let bg = RGB.mode(ringPx)
        var p = Palette(top: bg.color, bottom: bg.color, text: .labelColor, background: bg)

        // A gradient only when two opposite sides differ and agree with the sides between
        // them; otherwise a band that touches a neighbouring shape fakes one.
        if topPx.count > 8, botPx.count > 8, leftPx.count > 2, rightPx.count > 2 {
            let t = RGB.mode(topPx), b = RGB.mode(botPx), l = RGB.mode(leftPx), r = RGB.mode(rightPx)
            if t.dist(b) > 0.05, l.dist(r) < 0.04, RGB.purity(topPx) > 0.6, RGB.purity(botPx) > 0.6,
               l.dist(t.mix(b, 0.5)) < 0.06 {   // the sides must sit between top and bottom
                p.top = t.color; p.bottom = b.color; p.axis = .vertical
            }
            else if l.dist(r) > 0.05, t.dist(b) < 0.04, RGB.purity(leftPx) > 0.6, RGB.purity(rightPx) > 0.6,
                    t.dist(l.mix(r, 0.5)) < 0.05 {   // top/bottom must sit between the two sides
                p.top = l.color; p.bottom = r.color; p.axis = .horizontal
            }
        }

        // Text: inner pixels far from the background; take the farthest quarter.
        var far: [(RGB, Double)] = []
        for (c, _) in insidePx {
            let d = c.dist(bg)
            if d > 0.18 { far.append((c, d)) }
        }
        var text: RGB
        if far.count >= 4 {
            far.sort { $0.1 > $1.1 }
            text = RGB.median(far.prefix(max(4, far.count / 4)).map(\.0))
        } else {
            text = bg.luma > 0.5 ? RGB(0.1, 0.1, 0.1) : RGB(0.95, 0.95, 0.95)
        }
        if abs(text.luma - bg.luma) < 0.25 && text.dist(bg) < 0.35 {
            text = bg.luma > 0.5 ? RGB(0.08, 0.08, 0.08) : RGB(0.97, 0.97, 0.97)
        }
        p.text = text.color
        p.ink = text
        return p
    }
}

struct RGB {
    var r, g, b: Double
    init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
    var luma: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
    var color: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
    func dist(_ o: RGB) -> Double { ((r - o.r) * (r - o.r) + (g - o.g) * (g - o.g) + (b - o.b) * (b - o.b)).squareRoot() }
    func mix(_ o: RGB, _ t: Double) -> RGB { RGB(r + (o.r - r) * t, g + (o.g - g) * t, b + (o.b - b) * t) }
    /// Most common color (4 bits per channel buckets), averaged within its bucket.
    /// Share of pixels in the most common bucket: near 1 for a plain background.
    static func purity(_ s: [RGB]) -> Double {
        guard !s.isEmpty else { return 0 }
        var counts: [Int: Int] = [:]
        for c in s { counts[Int(c.r * 15.99) << 8 | Int(c.g * 15.99) << 4 | Int(c.b * 15.99), default: 0] += 1 }
        return Double(counts.values.max() ?? 0) / Double(s.count)
    }

    static func mode(_ s: [RGB]) -> RGB {
        var buckets: [Int: (Int, Double, Double, Double)] = [:]
        for c in s {
            let k = Int(c.r * 15.99) << 8 | Int(c.g * 15.99) << 4 | Int(c.b * 15.99)
            let v = buckets[k] ?? (0, 0, 0, 0)
            buckets[k] = (v.0 + 1, v.1 + c.r, v.2 + c.g, v.3 + c.b)
        }
        guard let best = buckets.values.max(by: { $0.0 < $1.0 }) else { return RGB(1, 1, 1) }
        let n = Double(best.0)
        return RGB(best.1 / n, best.2 / n, best.3 / n)
    }

    static func median(_ s: [RGB]) -> RGB {
        func m(_ v: [Double]) -> Double { let v = v.sorted(); return v[v.count / 2] }
        return RGB(m(s.map(\.r)), m(s.map(\.g)), m(s.map(\.b)))
    }
}

extension NSColor {
    func distance(to o: NSColor) -> CGFloat {
        guard let a = usingColorSpace(.sRGB), let b = o.usingColorSpace(.sRGB) else { return 1 }
        let dr = a.redComponent - b.redComponent, dg = a.greenComponent - b.greenComponent, db = a.blueComponent - b.blueComponent
        return (dr * dr + dg * dg + db * db).squareRoot()
    }
}
