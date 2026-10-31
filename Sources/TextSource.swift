import AppKit
import Vision
import ApplicationServices

/// One piece of on-screen text to translate. `rect` is the glyph area in global AppKit points.
struct TextItem {
    var text: String
    var rect: CGRect
    var lines: Int
    var font: NSFont?            // known only for Accessibility text
    var size: CGFloat?           // estimated point size for OCR text
    var glyphHeight: CGFloat?    // median height of the single OCR lines a paragraph was merged from
    var block: Int?              // web text: the paragraph-level element it sits in
    var linesWidth: CGFloat?     // summed width of those lines
    var align: NSTextAlignment = .left
    var fromAX = false

    var lineHeight: CGFloat { rect.height / CGFloat(max(1, lines)) }
    var isCJK: Bool { text.unicodeScalars.contains { (0x3040...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) } }
    var hasLetters: Bool { text.unicodeScalars.contains { CharacterSet.letters.contains($0) } }

    /// File names, URLs, paths, emails, handles and code-ish tokens read the same in every
    /// language; translating them only mangles them.
    var isLiteral: Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        if font?.isFixedPitch == true { return true }
        // Whole lines of code or shell: operators, flags, assignments, or mostly symbols.
        if t.range(of: #"&&|\|\||\s\|\s|^\$\s|\s--?[a-zA-Z]|\b\w+=[^\s]|[{};]\s*$|<<|>>|::|->|=>"#, options: .regularExpression) != nil { return true }
        let visible = t.unicodeScalars.filter { !CharacterSet.whitespaces.contains($0) }
        let symbols = visible.filter { "[]{}()<>=;:/\\|&$#*_~`'\"".unicodeScalars.contains($0) }.count
        if visible.count >= 8, Double(symbols) / Double(visible.count) > 0.18 { return true }
        if t.contains("://") || t.hasPrefix("www.") || t.hasPrefix("/") || t.hasPrefix("~/") || t.hasPrefix("@") || t.hasPrefix("#") { return true }
        guard !t.contains(" ") else { return false }
        if t.contains("@"), t.contains(".") { return true }
        return t.range(of: #"^[^\s.][^\s]*\.[a-z][a-z0-9]{0,4}$"#, options: .regularExpression) != nil
            || t.range(of: #"[_/\\]|[a-z][A-Z]|\(\)"#, options: .regularExpression) != nil
    }
}

// MARK: - OCR

enum OCR {
    /// Recognizes text lines in the snapshot and groups them into paragraphs. Recognition
    /// runs in the helper process (see OCRHelper) so the app itself stays small.
    static func items(in snap: Snapshot, fast: Bool = false) async -> [TextItem] {
        let fast = fast || !Prefs.accurateOCR
        let found = await OCRHelper.shared.recognize(snap.pixels, fast: fast, minHeight: 7 * snap.scale)
        let lines: [TextItem] = found.map { (t, b) in
            let r = CGRect(x: snap.frame.minX + b.minX * snap.frame.width, y: snap.frame.minY + b.minY * snap.frame.height,
                           width: b.width * snap.frame.width, height: b.height * snap.frame.height)
            return TextItem(text: t, rect: r, lines: 1)
        }
        return paragraphs(lines)
    }

    /// Vision text recognition: lines with normalized, bottom-left-origin boxes.
    static func recognize(_ image: CGImage, fast: Bool, minHeight: CGFloat) -> [(String, CGRect)] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = fast ? .fast : .accurate
        req.usesLanguageCorrection = !fast
        req.automaticallyDetectsLanguage = true
        req.minimumTextHeight = Float(minHeight) / Float(max(1, image.height))
        imageSize = CGSize(width: image.width, height: image.height)
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([req])
        var out: [(String, CGRect)] = []
        for obs in req.results ?? [] {
            guard let cand = obs.topCandidates(1).first, cand.confidence > 0.3 else { continue }
            for (t, r) in split(cand, obs.boundingBox) {
                let (t, r) = stripIcons(t.trimmingCharacters(in: .whitespaces), r)
                if !t.isEmpty { out.append((t, r)) }
            }
        }
        return out
    }

    /// Toolbar and list icons next to a label come back as a stray symbol ("_ Settings",
    /// "• Inbox"). Drop single non-alphanumeric tokens at either end and trim the box with them.
    static func stripIcons(_ t: String, _ r: CGRect) -> (String, CGRect) {
        var words = t.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard words.count > 1 else { return (t, r) }
        let total = CGFloat(max(1, t.count))
        var box = r
        func isIcon(_ w: String) -> Bool { w.count == 1 && !w.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) } }
        if let f = words.first, isIcon(f) {
            let cut = box.width * CGFloat(f.count + 1) / total
            box.origin.x += cut; box.size.width -= cut; words.removeFirst()
        }
        if words.count > 1, let l = words.last, isIcon(l) {
            box.size.width -= box.width * CGFloat(l.count + 1) / total; words.removeLast()
        }
        return (words.joined(separator: " "), box)
    }

    /// Vision reads a row of separate labels (a menu bar, a toolbar, table cells) as one
    /// line. Its word boxes swallow the gaps, so a word whose box is much wider than the
    /// word itself would be at that size is taken to end a label. Only lines that are
    /// clearly wider than their text are considered, so ordinary sentences stay whole.
    private static func split(_ cand: VNRecognizedText, _ box: CGRect) -> [(String, CGRect)] {
        let s = cand.string
        let hPx = box.height * imageSize.height
        guard s.contains(" "), hPx > 4 else { return [(s, box)] }
        let font = NSFont.systemFont(ofSize: hPx)
        func width(_ t: Substring) -> CGFloat { (String(t) as NSString).size(withAttributes: [.font: font]).width }
        guard box.width * imageSize.width > width(Substring(s)) * 1.2 else { return [(s, box)] }
        var words: [(Range<String.Index>, CGRect)] = []
        var i = s.startIndex
        while let start = s[i...].firstIndex(where: { $0 != " " }) {
            let end = s[start...].firstIndex(of: " ") ?? s.endIndex
            guard let b = (try? cand.boundingBox(for: start..<end))??.boundingBox else { return [(s, box)] }
            words.append((start..<end, b))
            i = end
        }
        guard words.count > 1 else { return [(s, box)] }
        var parts: [(String, CGRect)] = []
        var cur = words[0]
        for (k, w) in words.enumerated() {
            if k > 0 { cur = (cur.0.lowerBound..<w.0.upperBound, cur.1.union(w.1)) }
            let excess = w.1.width * imageSize.width - width(s[w.0])
            if excess > hPx * 1.0 || k == words.count - 1 {
                // Trim the box back to the text so the gap stays uncovered.
                var r = cur.1
                r.size.width = min(r.width, width(s[cur.0]) / imageSize.width * 1.05)
                parts.append((String(s[cur.0]), CGRect(x: r.minX, y: box.minY, width: r.width, height: box.height)))
                if k + 1 < words.count { cur = words[k + 1]; cur.0 = cur.0.lowerBound..<cur.0.lowerBound }
            }
        }
        return parts.filter { !$0.0.isEmpty }
    }

    nonisolated(unsafe) private static var imageSize = CGSize(width: 1, height: 1)

    /// Merges stacked lines that read as one paragraph so they are translated together.
    /// Short lines (menu items, buttons, list rows) stay separate.
    static func paragraphs(_ lines: [TextItem]) -> [TextItem] {
        let sorted = lines.sorted { $0.rect.maxY > $1.rect.maxY }   // top to bottom
        var out: [TextItem] = []
        var used = [Bool](repeating: false, count: sorted.count)
        for i in sorted.indices where !used[i] {
            used[i] = true
            var block = sorted[i]
            var last = sorted[i]
            var lefts = [last.rect.minX], centers = [last.rect.midX], heights = [last.rect.height], widths = [last.rect.width]
            var j = i + 1
            while j < sorted.count {
                if used[j] { j += 1; continue }
                let n = sorted[j]
                let h = last.rect.height
                let gap = last.rect.minY - n.rect.maxY
                if gap > h * 1.2 { if n.rect.maxY < last.rect.minY - h * 2 { break } ; j += 1; continue }
                let similarHeight = abs(n.rect.height - h) < h * 0.3
                let overlapsX = n.rect.minX < last.rect.maxX && n.rect.maxX > last.rect.minX
                let alignedLeft = abs(n.rect.minX - block.rect.minX) < h * 1.2
                let alignedCenter = abs(n.rect.midX - block.rect.midX) < h * 1.2
                let lastIsLong = last.rect.width > max(h * 9, block.rect.width * 0.6)
                let endsSentence = last.text.last.map { ".!?。！？:：".contains($0) } ?? false
                if gap < h * 0.7, gap > -h * 0.3, similarHeight, overlapsX, alignedLeft || alignedCenter, lastIsLong, !endsSentence {
                    used[j] = true
                    let joiner = (block.isCJK || block.text.hasSuffix("-")) ? "" : " "
                    if block.text.hasSuffix("-") && !block.isCJK { block.text.removeLast() }
                    block.text += joiner + n.text
                    block.rect = block.rect.union(n.rect)
                    block.lines += 1
                    lefts.append(n.rect.minX); centers.append(n.rect.midX); heights.append(n.rect.height); widths.append(n.rect.width)
                    last = n
                }
                j += 1
            }
            block.glyphHeight = heights.sorted()[heights.count / 2]
            block.linesWidth = widths.reduce(0, +)
            if block.lines > 1 {
                let leftSpread = (lefts.max()! - lefts.min()!), centerSpread = (centers.max()! - centers.min()!)
                if centerSpread < leftSpread * 0.5 { block.align = .center }
            }
            out.append(block)
        }
        return out
    }
}

// MARK: - Accessibility

/// Reads text straight out of the frontmost app's Accessibility tree: exact strings,
/// exact frames and the real font, so the translation can sit where the label was.
enum AXText {
    static var trusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    private static var enabledPIDs = Set<pid_t>()

    /// `beyondWindow`: also text scrolled out of the window (web pages and text views keep
    /// it in their tree), to translate ahead of time.
    static func items(app: NSRunningApplication, within region: CGRect, budget: TimeInterval = 0.35, beyondWindow: Bool = false) -> [TextItem] {
        guard trusted else { return [] }
        let pid = app.processIdentifier
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.25)
        if !enabledPIDs.contains(pid) {
            // Chromium and Electron only build their tree when asked.
            AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            enabledPIDs.insert(pid)
        }
        // Web pages have far more nodes than native windows.
        let deadline = Date().addingTimeInterval(Prefs.webOptimize ? max(budget, 0.6) : budget)
        var out: [TextItem] = []
        var visited = 0
        let windows: [AXUIElement] = attr(root, kAXWindowsAttribute) ?? []
        for w in windows {
            guard let wf = frame(w), wf.intersects(region) else { continue }
            walk(w, clip: beyondWindow ? region : wf.intersection(region), depth: 0, deadline: deadline, block: nil, visited: &visited, out: &out)
        }
        return Prefs.webOptimize ? joinInlineRuns(out) : out
    }

    /// Inline roles inside web text: a link or a styled run inside a paragraph belongs to
    /// the paragraph, so it's translated together with the rest of the sentence.
    private static let inlineRoles: Set<String> = ["AXLink", "AXStaticText", "AXEmphasis", "AXStrong", "AXMark", "AXCode"]

    /// Any browser (and web-based apps): text inside a web area arrives as separate runs
    /// wherever a link or style changes. Consecutive runs from the same paragraph-level
    /// element are joined into one item, so a sentence isn't translated in pieces.
    static func joinInlineRuns(_ items: [TextItem]) -> [TextItem] {
        var out: [TextItem] = []
        for it in items {
            // Runs of one sentence share a line (a link inside the text overlaps the line the
            // text before it ends on); stacked labels (a title over a subtitle) don't.
            let sharesLine: Bool = {
                guard let last = out.last else { return false }
                let overlap = min(last.rect.maxY, it.rect.maxY) - max(last.rect.minY, it.rect.minY)
                // ...and follow on closely, unlike a badge pinned to the far end of a row.
                return overlap > min(last.lineHeight, it.lineHeight) * 0.3 && it.rect.minX - last.rect.maxX < it.lineHeight * 1.5
            }()
            if var last = out.last, let b = it.block, b == last.block, sharesLine,
               last.text.count + it.text.count < 2000 {
                let glue = last.text.hasSuffix(" ") || it.text.hasPrefix(" ") || ",.;:!?)".contains(it.text.first ?? " ") ? "" : " "
                last.text = (last.text + glue + it.text).trimmingCharacters(in: .whitespaces)
                let h = min(last.lineHeight, it.lineHeight)
                last.rect = last.rect.union(it.rect)
                last.lines = max(1, Int((last.rect.height / max(1, h)).rounded()))
                out[out.count - 1] = last
            } else {
                out.append(it)
            }
        }
        return out
    }

    private static let textRoles: Set<String> = ["AXStaticText", "AXTextArea", "AXTextField"]
    private static let titledRoles: Set<String> = ["AXButton", "AXMenuButton", "AXPopUpButton", "AXCheckBox",
                                                   "AXRadioButton", "AXMenuItem", "AXMenuBarItem", "AXTab", "AXDisclosureTriangle"]
    private static let clipRoles: Set<String> = ["AXScrollArea", "AXWebArea", "AXList", "AXTable", "AXOutline", "AXGroup"]

    private static func walk(_ e: AXUIElement, clip: CGRect, depth: Int, deadline: Date, block: Int?, visited: inout Int, out: inout [TextItem]) {
        visited += 1
        if depth > 60 || visited > 6000 || Date() > deadline { return }
        let keys = [kAXRoleAttribute, kAXValueAttribute, kAXTitleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute] as CFArray
        var raw: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(e, keys, AXCopyMultipleAttributeOptions(rawValue: 0), &raw) == .success,
              let vals = raw as? [AnyObject], vals.count == 6 else { return }
        let role = vals[0] as? String ?? ""
        var f: CGRect?
        if let p = point(vals[3]), let s = size(vals[4]) { f = Coords.fromQuartz(CGRect(origin: p, size: s)) }
        if let f, !f.isEmpty, !f.intersects(clip) { return }   // whole subtree is off screen
        var clip = clip
        if let f, clipRoles.contains(role), role != "AXGroup" { clip = clip.intersection(f) }

        if let f, !f.isEmpty {
            var text: String?
            if textRoles.contains(role), let v = vals[1] as? String {
                // Editable fields hold the user's own typing; leave them alone.
                var settable: DarwinBoolean = false
                AXUIElementIsAttributeSettable(e, kAXValueAttribute as CFString, &settable)
                if role == "AXStaticText" || !settable.boolValue { text = v }
            } else if titledRoles.contains(role), let t = vals[2] as? String {
                text = t
            }
            if let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, t.count < 4000 {
                let glyphs = bounds(e, length: (t as NSString).length, isText: textRoles.contains(role)) ?? f
                let visible = glyphs.intersection(clip)
                if visible.height >= glyphs.height * 0.6, visible.width >= glyphs.width * 0.5 {
                    let font = self.font(e, isText: textRoles.contains(role))
                    let lh = (font?.pointSize ?? glyphs.height) * 1.25
                    let lines = max(1, Int((glyphs.height / lh).rounded()))
                    var item = TextItem(text: t, rect: glyphs, lines: lines, font: font, fromAX: true)
                    item.block = block
                    out.append(item)
                }
                if role == "AXStaticText" || titledRoles.contains(role) { return }
            }
        }
        guard let kids = vals[5] as? [AXUIElement] else { return }
        // Inside a web area, remember the nearest paragraph-level element for joinInlineRuns.
        let childBlock: Int? = role == "AXWebArea" ? Int(CFHash(e))
            : block == nil ? nil : (inlineRoles.contains(role) ? block : Int(CFHash(e)))
        for k in kids { walk(k, clip: clip, depth: depth + 1, deadline: deadline, block: childBlock, visited: &visited, out: &out) }
    }

    /// Element under a screen point (AppKit coordinates).
    static func element(at p: CGPoint) -> AXUIElement? {
        let q = Coords.toQuartz(p)
        var el: AXUIElement?
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.2)
        return AXUIElementCopyElementAtPosition(sys, Float(q.x), Float(q.y), &el) == .success ? el : nil
    }

    /// The paragraph under `p` (AppKit coordinates) inside a text view, so pointing at one
    /// line of a long document translates that paragraph rather than the whole document.
    static func paragraph(in e: AXUIElement, at p: CGPoint) -> (String, CGRect?)? {
        guard let value: String = attr(e, kAXValueAttribute), value.contains(where: \.isNewline) else { return nil }
        var q = Coords.toQuartz(p)
        guard let pv = AXValueCreate(.cgPoint, &q) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(e, kAXRangeForPositionParameterizedAttribute as CFString, pv, &out) == .success,
              let rv = out, CFGetTypeID(rv) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        guard AXValueGetValue(rv as! AXValue, .cfRange, &r) else { return nil }
        let ns = value as NSString
        guard r.location >= 0, r.location < ns.length else { return nil }
        let para = ns.paragraphRange(for: NSRange(location: r.location, length: 0))
        let text = ns.substring(with: para).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var range = CFRange(location: para.location, length: para.length)
        var frame: CGRect?
        if let rr = AXValueCreate(.cfRange, &range) {
            var b: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(e, kAXBoundsForRangeParameterizedAttribute as CFString, rr, &b) == .success,
               let bv = b, CFGetTypeID(bv) == AXValueGetTypeID() {
                var rect = CGRect.zero
                if AXValueGetValue(bv as! AXValue, .cgRect, &rect) { frame = Coords.fromQuartz(rect) }
            }
        }
        return (String(text.prefix(2000)), frame)
    }

    /// Text of an element, or of its static-text children for groups like table cells.
    static func text(of e: AXUIElement) -> (String, CGRect?)? {
        for key in [kAXValueAttribute, kAXTitleAttribute] {
            if let s: String = attr(e, key), !s.trimmingCharacters(in: .whitespaces).isEmpty { return (s, frame(e)) }
        }
        let kids: [AXUIElement] = attr(e, kAXChildrenAttribute) ?? []
        let parts = kids.prefix(20).compactMap { (attr($0, kAXValueAttribute) as String?) }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : (parts.joined(separator: " "), frame(e))
    }

    /// Selected text in the frontmost app (asked of the app itself, which is more reliable
    /// than the system-wide focus), falling back to the system-wide focused element.
    static func selectedText() -> String? {
        var owners: [AXUIElement] = []
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() {
            owners.append(AXUIElementCreateApplication(app.processIdentifier))
        }
        owners.append(AXUIElementCreateSystemWide())
        for o in owners {
            AXUIElementSetMessagingTimeout(o, 0.3)
            if let focused: AXUIElement = attr(o, kAXFocusedUIElementAttribute),
               let s: String = attr(focused, kAXSelectedTextAttribute), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return s
            }
        }
        return nil
    }

    // MARK: helpers

    static func attr<T>(_ e: AXUIElement, _ key: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, key as CFString, &v) == .success else { return nil }
        return v as? T
    }

    static func frame(_ e: AXUIElement) -> CGRect? {
        guard let p = point(attr(e, kAXPositionAttribute) as AXValue?), let s = size(attr(e, kAXSizeAttribute) as AXValue?) else { return nil }
        return Coords.fromQuartz(CGRect(origin: p, size: s))
    }

    private static func point(_ v: AnyObject?) -> CGPoint? {
        guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    private static func size(_ v: AnyObject?) -> CGSize? {
        guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }

    /// Tight bounds of the glyphs, when the element can report them.
    private static func bounds(_ e: AXUIElement, length: Int, isText: Bool) -> CGRect? {
        guard isText, length > 0 else { return nil }
        var range = CFRange(location: 0, length: length)
        guard let rv = AXValueCreate(.cfRange, &range) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(e, kAXBoundsForRangeParameterizedAttribute as CFString, rv, &out) == .success,
              let v = out, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CGRect.zero
        guard AXValueGetValue(v as! AXValue, .cgRect, &r), r.width > 1, r.height > 1 else { return nil }
        return Coords.fromQuartz(r)
    }

    private static func font(_ e: AXUIElement, isText: Bool) -> NSFont? {
        guard isText else { return nil }
        var range = CFRange(location: 0, length: 1)
        guard let rv = AXValueCreate(.cfRange, &range) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(e, kAXAttributedStringForRangeParameterizedAttribute as CFString, rv, &out) == .success,
              let s = out as? NSAttributedString, s.length > 0,
              let f = s.attribute(NSAttributedString.Key(kAXFontTextAttribute.takeUnretainedValue() as String), at: 0, effectiveRange: nil) as? [String: Any],
              let sizeVal = f[kAXFontSizeKey.takeUnretainedValue() as String] as? CGFloat else { return nil }
        let name = f[kAXFontNameKey.takeUnretainedValue() as String] as? String
        return name.flatMap { NSFont(name: $0, size: sizeVal) } ?? .systemFont(ofSize: sizeVal)
    }
}
