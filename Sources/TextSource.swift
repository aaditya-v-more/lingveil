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
    var align: NSTextAlignment = .left
    var fromAX = false

    var lineHeight: CGFloat { rect.height / CGFloat(max(1, lines)) }
    var isCJK: Bool { text.unicodeScalars.contains { (0x3040...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) } }
    var hasLetters: Bool { text.unicodeScalars.contains { CharacterSet.letters.contains($0) } }

    /// File names, URLs, paths, emails, handles and code-ish tokens read the same in every
    /// language; translating them only mangles them.
    var isLiteral: Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
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
                let t = t.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { out.append((t, r)) }
            }
        }
        return out
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
            var lefts = [last.rect.minX], centers = [last.rect.midX]
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
                    lefts.append(n.rect.minX); centers.append(n.rect.midX)
                    last = n
                }
                j += 1
            }
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

    static func items(app: NSRunningApplication, within region: CGRect, budget: TimeInterval = 0.35) -> [TextItem] {
        guard trusted else { return [] }
        let pid = app.processIdentifier
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.25)
        if !enabledPIDs.contains(pid) {
            // Chromium and Electron only build their tree when asked.
            AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            enabledPIDs.insert(pid)
        }
        let deadline = Date().addingTimeInterval(budget)
        var out: [TextItem] = []
        var visited = 0
        let windows: [AXUIElement] = attr(root, kAXWindowsAttribute) ?? []
        for w in windows {
            guard let wf = frame(w), wf.intersects(region) else { continue }
            walk(w, clip: wf.intersection(region), depth: 0, deadline: deadline, visited: &visited, out: &out)
        }
        return out
    }

    private static let textRoles: Set<String> = ["AXStaticText", "AXTextArea", "AXTextField"]
    private static let titledRoles: Set<String> = ["AXButton", "AXMenuButton", "AXPopUpButton", "AXCheckBox",
                                                   "AXRadioButton", "AXMenuItem", "AXMenuBarItem", "AXTab", "AXDisclosureTriangle"]
    private static let clipRoles: Set<String> = ["AXScrollArea", "AXWebArea", "AXList", "AXTable", "AXOutline", "AXGroup"]

    private static func walk(_ e: AXUIElement, clip: CGRect, depth: Int, deadline: Date, visited: inout Int, out: inout [TextItem]) {
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
                    out.append(TextItem(text: t, rect: glyphs, lines: lines, font: font, fromAX: true))
                }
                if role == "AXStaticText" || titledRoles.contains(role) { return }
            }
        }
        guard let kids = vals[5] as? [AXUIElement] else { return }
        for k in kids { walk(k, clip: clip, depth: depth + 1, deadline: deadline, visited: &visited, out: &out) }
    }

    /// Element under a screen point (AppKit coordinates).
    static func element(at p: CGPoint) -> AXUIElement? {
        let q = Coords.toQuartz(p)
        var el: AXUIElement?
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.2)
        return AXUIElementCopyElementAtPosition(sys, Float(q.x), Float(q.y), &el) == .success ? el : nil
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

    static func selectedText() -> String? {
        let sys = AXUIElementCreateSystemWide()
        guard let focused: AXUIElement = attr(sys, kAXFocusedUIElementAttribute) else { return nil }
        let s: String? = attr(focused, kAXSelectedTextAttribute)
        return s?.isEmpty == false ? s : nil
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
