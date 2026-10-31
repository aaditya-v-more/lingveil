import AppKit

/// Colors sampled from the screenshot around and inside a piece of text, so the
/// translation can be painted in the same colors as the original.
struct Palette {
    var top: NSColor
    var bottom: NSColor
    var text: NSColor
    var isGradient: Bool { !Palette.close(top, bottom, 0.05) }

    static let fallback = Palette(top: .windowBackgroundColor, bottom: .windowBackgroundColor, text: .labelColor)

    static func close(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> Bool { a.distance(to: b) < t }

    /// `px` is the text's rect in image pixels. Samples a ring just outside it for the
    /// background and the pixels that differ most from that background for the text.
    static func sample(_ image: CGImage, px: CGRect) -> Palette {
        let ring = max(2, min(6, px.height * 0.15)).rounded()
        let outer = px.insetBy(dx: -ring, dy: -ring).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard outer.width >= 4, outer.height >= 4, let crop = image.cropping(to: outer) else { return .fallback }

        let w = crop.width, h = crop.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let drew: Bool = buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drew else { return .fallback }

        // Inner rect in crop coordinates (rows top to bottom).
        let ix0 = Int(px.minX - outer.minX), iy0 = Int(px.minY - outer.minY)
        let ix1 = ix0 + Int(px.width), iy1 = iy0 + Int(px.height)
        var topPx: [RGB] = [], botPx: [RGB] = [], sidePx: [RGB] = [], inner: [(RGB, Int)] = []
        let step = max(1, (w * h) / 40_000)   // cap work on huge blocks
        var i = 0
        for y in 0..<h {
            for x in 0..<w {
                i += 1
                if i % step != 0 { continue }
                let o = (y * w + x) * 4
                let c = RGB(Double(buf[o]) / 255, Double(buf[o + 1]) / 255, Double(buf[o + 2]) / 255)
                let inside = x >= ix0 && x < ix1 && y >= iy0 && y < iy1
                if inside { inner.append((c, y)) }
                else if y < iy0 { topPx.append(c) }
                else if y >= iy1 { botPx.append(c) }
                else { sidePx.append(c) }
            }
        }
        let all = topPx + botPx + sidePx
        guard !all.isEmpty else { return .fallback }
        let bgAll = RGB.median(all)
        var top = topPx.count > 8 ? RGB.median(topPx + sidePx.prefix(sidePx.count / 2)) : bgAll
        var bot = botPx.count > 8 ? RGB.median(botPx + sidePx.suffix(sidePx.count / 2)) : bgAll
        if top.dist(bot) < 0.05 { top = bgAll; bot = bgAll }

        // Text: inner pixels far from the (row-interpolated) background.
        let span = Double(max(1, iy1 - iy0))
        var far: [(RGB, Double)] = []
        for (c, y) in inner {
            let t = Double(y - iy0) / span
            let bg = top.mix(bot, t)
            let d = c.dist(bg)
            if d > 0.18 { far.append((c, d)) }
        }
        var text: RGB
        if far.count >= 4 {
            far.sort { $0.1 > $1.1 }
            text = RGB.median(far.prefix(max(4, far.count / 4)).map(\.0))
        } else {
            text = bgAll.luma > 0.5 ? RGB(0.1, 0.1, 0.1) : RGB(0.95, 0.95, 0.95)
        }
        if abs(text.luma - bgAll.luma) < 0.25 {
            text = bgAll.luma > 0.5 ? RGB(0.08, 0.08, 0.08) : RGB(0.97, 0.97, 0.97)
        }
        return Palette(top: top.color, bottom: bot.color, text: text.color)
    }
}

struct RGB {
    var r, g, b: Double
    init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
    var luma: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
    var color: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
    func dist(_ o: RGB) -> Double { ((r - o.r) * (r - o.r) + (g - o.g) * (g - o.g) + (b - o.b) * (b - o.b)).squareRoot() }
    func mix(_ o: RGB, _ t: Double) -> RGB { RGB(r + (o.r - r) * t, g + (o.g - g) * t, b + (o.b - b) * t) }
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
