import AppKit

/// Snapshot -> text items (Accessibility + OCR) -> translations -> colored blocks.
enum Pipeline {
    /// Finds text in the snapshot. The frontmost app's Accessibility text is preferred
    /// (exact strings, frames, fonts); OCR, run at the same time, confirms that text is
    /// actually visible and fills in anything Accessibility can't see (images, games, video).
    static func items(in snap: Snapshot, app: NSRunningApplication?, fastOCR: Bool = false) async -> [TextItem] {
        async let ocr = OCR.items(in: snap, fast: fastOCR)
        var ax: [TextItem] = []
        if Prefs.useAccessibility, let app, app.processIdentifier != getpid() {
            ax = await Task.detached(priority: .userInitiated) { AXText.items(app: app, within: snap.frame) }.value
        }
        let seen = estimateSizes(await ocr)
        guard !ax.isEmpty else { return seen }

        func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
            let i = a.intersection(b); return i.isNull ? 0 : i.width * i.height
        }
        var axValid: [TextItem] = []
        for a in ax where seen.contains(where: { overlap($0.rect, a.rect) > 0 }) {
            if !axValid.contains(where: { $0.text == a.text && overlap($0.rect, a.rect) > a.rect.width * a.rect.height * 0.5 }) {
                axValid.append(a)
            }
        }
        let extra = seen.filter { o in
            let area = o.rect.width * o.rect.height
            return !axValid.contains { overlap($0.rect, o.rect) > area * 0.25 }
        }
        return axValid + extra
    }

    /// Translates items and samples colors for each. Items already in the target language,
    /// or with nothing to translate (numbers, symbols), are left out so the original shows.
    static func blocks(for items: [TextItem], in snap: Snapshot, to target: Language) async throws -> [Block] {
        let todo = items.filter { $0.hasLetters && !Detect.isAlready($0.text, in: target) }
        guard !todo.isEmpty else { return [] }
        let translated = try await Translation.translate(todo.map(\.text), to: target)
        return await Task.detached(priority: .userInitiated) {
            zip(todo, translated).compactMap { item, t -> Block? in
                let clean = t.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty, clean.caseInsensitiveCompare(item.text) != .orderedSame else { return nil }
                return Block(item: item, translation: caseMatched(clean, original: item.text), palette: Palette.sample(snap.image, px: snap.pixelRect(item.rect)))
            }
        }.value
    }

    /// OCR boxes vary in height with the glyphs inside them, so the size is taken from how
    /// wide the original text would be in the system font, then sizes within ~10% of each
    /// other are snapped together so a list keeps one size the way the app drew it.
    static func estimateSizes(_ items: [TextItem]) -> [TextItem] {
        var out = items.map { it -> TextItem in
            var it = it
            let byHeight = it.lineHeight * (it.lines > 1 ? 0.74 : 0.8)
            var size = byHeight
            if it.lines == 1 {
                let w = (it.text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 20)]).width
                if w > 0 { size = min(max(20 * it.rect.width / w, byHeight * 0.75), byHeight * 1.15) }
            }
            it.size = max(7, size)
            return it
        }
        let sizes = out.compactMap(\.size).sorted()
        var clusters: [[CGFloat]] = []
        for s in sizes {
            if let last = clusters.last?.last, s <= last * 1.1 { clusters[clusters.count - 1].append(s) } else { clusters.append([s]) }
        }
        for i in out.indices {
            guard let s = out[i].size, let c = clusters.first(where: { $0.contains(s) }) else { continue }
            out[i].size = (c[c.count / 2] * 2).rounded() / 2
        }
        return out
    }

    /// Short labels come back lowercase from some engines ("send"); match sentence case
    /// when the source script has no case of its own.
    static func caseMatched(_ t: String, original: String) -> String {
        guard let f = t.first, f.isLowercase else { return t }
        let o = original.first { $0.isLetter }
        if let o, o.isUppercase || o.isLowercase { return o.isUppercase ? f.uppercased() + t.dropFirst() : t }
        return f.uppercased() + t.dropFirst()
    }

    static var frontApp: NSRunningApplication? {
        let a = NSWorkspace.shared.frontmostApplication
        return a?.processIdentifier == getpid() ? nil : a
    }
}
