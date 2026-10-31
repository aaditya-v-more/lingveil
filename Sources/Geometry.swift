import AppKit

/// Measurements taken from the screenshot around one piece of text: where its letters
/// really end, how much plain background surrounds it (so a longer translation only grows
/// into empty space, and padding never paints over a control's border), and how thick
/// its strokes are (to pick a font weight).
struct Surroundings {
    var left: CGFloat = 0, right: CGFloat = 0, up: CGFloat = 0, down: CGFloat = 0   // free space in points
    var boundedLeft = false, boundedRight = false   // background ends at a shape edge on that side
    var stroke: CGFloat = 0                         // median stroke width / line height
}

enum Refine {
    /// Grows `item.rect` to cover letters OCR missed at either end and measures the free
    /// background around it. `bg` is the background color the translation will be painted on.
    static func measure(_ item: inout TextItem, in snap: Snapshot, bg: RGB, text: RGB) -> Surroundings {
        let px = snap.pixels
        let s = snap.scale
        var r = snap.pixelRect(item.rect).integral
            .intersection(CGRect(x: 0, y: 0, width: px.width, height: px.height))
        guard r.width >= 2, r.height >= 2 else { return Surroundings() }
        let lineH = r.height / CGFloat(max(1, item.lines))
        let inkThreshold = max(0.16, min(0.4, text.dist(bg) * 0.45))
        // Ink = close to the text's own color, so an icon or a control next to the label
        // (a grey square, a colored dot) doesn't count as more letters.
        let textMatch = max(0.2, text.dist(bg) * 0.55)
        func isInk(_ x: Int, _ y: Int) -> Bool {
            let c = px.rgb(x, y)
            return c.dist(bg) > inkThreshold && c.dist(text) < textMatch
        }
        func isBackground(_ x: Int, _ y: Int) -> Bool { px.rgb(x, y).dist(bg) < 0.07 }
        let y0 = Int(r.minY + r.height * 0.12), y1 = max(y0 + 1, Int(r.maxY - r.height * 0.12))
        func columnHasInk(_ x: Int) -> Bool {
            guard x >= 0, x < px.width else { return false }
            return stride(from: y0, to: y1, by: 1).contains { isInk(x, $0) }
        }
        func columnIsBackground(_ x: Int) -> Bool {
            guard x >= 0, x < px.width else { return false }
            return stride(from: y0, to: y1, by: 2).allSatisfy { isBackground(x, $0) }
        }

        // 1. Trim the box to where text-colored ink starts and ends (an icon inside the OCR
        //    box isn't text), then extend past it while letters continue, stopping after a
        //    gap of a third of a line of plain background.
        let inkCols = (Int(r.minX)..<Int(r.maxX)).filter(columnHasInk)
        if let first = inkCols.first, let last = inkCols.last, last > first {
            r = CGRect(x: CGFloat(first), y: r.minY, width: CGFloat(last + 1 - first), height: r.height)
        }
        let gapStop = Int(max(3, lineH * 0.33))
        let reach = Int(lineH * 2)
        var maxX = Int(r.maxX), gap = 0
        for x in Int(r.maxX)..<min(px.width, Int(r.maxX) + reach) {
            if columnHasInk(x) { maxX = x + 1; gap = 0 } else { gap += 1; if gap > gapStop { break } }
        }
        var minX = Int(r.minX); gap = 0
        for x in stride(from: Int(r.minX) - 1, through: max(0, Int(r.minX) - reach), by: -1) {
            if columnHasInk(x) { minX = x; gap = 0 } else { gap += 1; if gap > gapStop { break } }
        }
        r = CGRect(x: CGFloat(minX), y: r.minY, width: CGFloat(maxX - minX), height: r.height)

        // 2. Free background on each side, up to 1.6x the width sideways and half a line
        //    above and below.
        // Skip the anti-aliased fringe right next to the letters before counting.
        var out = Surroundings()
        let sideCap = Int(max(r.width * 1.5, lineH * 8))
        let fringe = Int(max(2, lineH * 0.25))
        var x = maxX, skipped = 0
        while skipped < fringe, !columnIsBackground(x), x < px.width { x += 1; skipped += 1 }
        var n = skipped
        while n < sideCap, columnIsBackground(x) { n += 1; x += 1 }
        out.right = CGFloat(n) / s; out.boundedRight = n < sideCap
        x = minX - 1; skipped = 0
        while skipped < fringe, !columnIsBackground(x), x >= 0 { x -= 1; skipped += 1 }
        n = skipped
        while n < sideCap, columnIsBackground(x) { n += 1; x -= 1 }
        out.left = CGFloat(n) / s; out.boundedLeft = n < sideCap
        let vCap = Int(max(2, lineH * 0.5))
        func rowIsBackground(_ y: Int) -> Bool {
            guard y >= 0, y < px.height else { return false }
            return stride(from: minX, to: maxX, by: 2).allSatisfy { isBackground($0, y) }
        }
        n = 0; var y = Int(r.maxY)
        while n < vCap, rowIsBackground(y) { n += 1; y += 1 }
        out.down = CGFloat(n) / s
        n = 0; y = Int(r.minY) - 1
        while n < vCap, rowIsBackground(y) { n += 1; y -= 1 }
        out.up = CGFloat(n) / s

        // 3. Stroke width: median length of horizontal ink runs across the middle rows.
        var runs: [Int] = []
        for yy in stride(from: y0, to: y1, by: max(1, (y1 - y0) / 8)) {
            var run = 0
            for xx in minX..<maxX {
                if isInk(xx, yy) { run += 1 } else if run > 0 { runs.append(run); run = 0 }
            }
        }
        if runs.count >= 6 { out.stroke = CGFloat(runs.sorted()[runs.count / 2]) / lineH }

        // Back to global points.
        item.rect = CGRect(x: snap.frame.minX + r.minX / s, y: snap.frame.maxY - r.maxY / s, width: r.width / s, height: r.height / s)
        return out
    }
}
