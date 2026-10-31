import AppKit

/// Snapshot -> text items (Accessibility + OCR) -> translations -> colored blocks.
enum Pipeline {
    /// Finds text in the snapshot. The frontmost app's Accessibility text is preferred
    /// (exact strings, frames, fonts); OCR, run at the same time, confirms that text is
    /// actually visible and fills in anything Accessibility can't see (images, games, video).
    nonisolated(unsafe) static var timings = ""

    /// `accessibility: false` uses OCR only, for a frame that may no longer match what the
    /// app reports right now (the screen was moving when it was captured).
    static func items(in snap: Snapshot, app: NSRunningApplication?, fastOCR: Bool = false, accessibility: Bool = true) async -> [TextItem] {
        let t0 = Date()
        async let ocr = OCR.items(in: snap, fast: fastOCR)
        var ax: [TextItem] = []
        if accessibility, Prefs.useAccessibility, let app, app.processIdentifier != getpid() {
            ax = await Task.detached(priority: .userInitiated) { AXText.items(app: app, within: snap.frame) }.value
        }
        let axTime = Date().timeIntervalSince(t0)
        let seen = estimateSizes(await ocr)
        timings = String(format: "ax %.0f ms (%d), ocr done at %.0f ms (%d)", axTime * 1000, ax.count, Date().timeIntervalSince(t0) * 1000, seen.count)
        guard !ax.isEmpty else { return seen }

        func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
            let i = a.intersection(b); return i.isNull ? 0 : i.width * i.height
        }
        // Accessibility gives the exact text, but in web and Electron apps a whole paragraph
        // arrives as one element with no font, so its size and line count come from the OCR
        // lines that sit inside it (which also proves the text is actually visible).
        var axValid: [TextItem] = []
        for var a in ax {
            let inside = seen.filter { o in overlap(o.rect, a.rect) >= o.rect.width * o.rect.height * 0.5 }
            guard !inside.isEmpty else { continue }
            if axValid.contains(where: { $0.text == a.text && overlap($0.rect, a.rect) > a.rect.width * a.rect.height * 0.5 }) { continue }
            let ocrSize = inside.compactMap(\.size).sorted().dropFirst(inside.count / 2).first
            a.lines = max(1, inside.reduce(0) { $0 + $1.lines })
            if let f = a.font, let o = ocrSize, f.pointSize > o * 1.6 || f.pointSize < o * 0.6 { a.font = nil }
            if a.font == nil {
                a.size = ocrSize
                // The OCR lines give a tight box (an element's frame is often a whole row);
                // letters OCR missed at either end are added later from the pixels.
                a.rect = inside.dropFirst().reduce(inside[0].rect) { $0.union($1.rect) }
                if inside.count == 1 { a.align = inside[0].align }
            }
            axValid.append(a)
        }
        let extra = seen.filter { o in
            let area = o.rect.width * o.rect.height
            return !axValid.contains { overlap($0.rect, o.rect) > area * 0.25 } && !ax.contains { overlap($0.rect, o.rect) > area * 0.5 }
        }
        return axValid + extra
    }

    /// Translates items and samples colors for each. Items already in the target language,
    /// or with nothing to translate (numbers, symbols), are left out so the original shows.
    /// Work goes out in batches; `progress` receives everything finished so far as each
    /// batch lands, so most of the screen is painted before the slowest reply arrives.
    static func blocks(for items: [TextItem], in snap: Snapshot, to target: Language, focus: CGRect? = nil,
                       progress: (@MainActor ([Block]) -> Void)? = nil) async throws -> [Block] {
        let todo = items.filter { $0.hasLetters && !$0.isLiteral && !Detect.isAlready($0.text, in: target) }
        guard !todo.isEmpty else { return [] }
        let t0 = Date()
        // The window being worked in first, then top to bottom, so what the eye is on lands first.
        let ordered = todo.sorted { a, b in
            let fa = focus?.intersects(a.rect) ?? false, fb = focus?.intersects(b.rect) ?? false
            return fa != fb ? fa : a.rect.maxY > b.rect.maxY
        }
        // Network engines answer a batch at once; local models work line by line, so smaller
        // batches let the first lines appear while the rest are still being translated.
        let network = [.auto, .google, .googleCloud, .deepl].contains(Prefs.engine)
        let size = network ? 30 : 8
        // Online batches all go out at once; on-device engines are already busy with one batch
        // (they run lines in parallel inside it), so their batches go one after another.
        let concurrent = network ? Int.max : 1
        let batches = stride(from: 0, to: ordered.count, by: size).map { Array(ordered[$0..<min($0 + size, ordered.count)]) }
        var done: [Block] = []
        var firstError: Error?
        await withTaskGroup(of: Result<[Block], Error>.self) { g in
            var pending = batches[...]
            func addNext() {
                guard let batch = pending.popFirst() else { return }
                g.addTask {
                    do {
                        let translated = try await Translation.translate(batch.map(\.text), to: target)
                        return .success(zip(batch, translated).compactMap { item, t -> Block? in
                            let clean = t.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !clean.isEmpty, clean.caseInsensitiveCompare(item.text) != .orderedSame else { return nil }
                            var item = item
                            let palette = Palette.sample(snap.pixels, rect: snap.pixelRect(item.rect))
                            let before = item.rect.width
                            let around = Refine.measure(&item, in: snap, bg: palette.background, text: palette.ink)
                            // OCR boxes are often narrower than the letters; a size estimated from the
                            // narrow box is too small, so scale it with the measured width.
                            if !item.fromAX, item.lines == 1, let sz = item.size, before > 0, item.rect.width > before * 1.03 {
                                item.size = min(sz * item.rect.width / before, item.lineHeight * 1.1)
                            }
                            return Block(item: item, translation: caseMatched(clean, original: item.text), palette: palette, around: around)
                        })
                    } catch { return .failure(error) }
                }
            }
            for _ in 0..<min(concurrent, batches.count) { addNext() }
            for await r in g {
                addNext()
                switch r {
                case .success(let b):
                    done += b
                    if let progress { let snapshot = done; await MainActor.run { progress(snapshot) } }
                case .failure(let e): firstError = firstError ?? e
                }
            }
        }
        timings += String(format: ", translate %.0f ms (%d)", Date().timeIntervalSince(t0) * 1000, todo.count)
        if done.isEmpty, let firstError { throw firstError }
        return done
    }

    /// OCR boxes vary in height with the glyphs inside them, so the size is taken from how
    /// wide the original text would be in the system font, then sizes within ~10% of each
    /// other are snapped together so a list keeps one size the way the app drew it.
    static func estimateSizes(_ items: [TextItem]) -> [TextItem] {
        var out = items.map { it -> TextItem in
            var it = it
            // Paragraphs: size from their single lines' glyph height, not the line pitch,
            // which includes the app's line spacing.
            let byHeight = (it.lines > 1 ? (it.glyphHeight ?? it.lineHeight / 1.2) : it.lineHeight) * 0.8
            var size = byHeight
            if it.lines > 1 {
                // Paragraph: the width its text takes, summed over its lines.
                let w = (it.text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 20)]).width
                let filled = it.linesWidth ?? it.rect.width * (CGFloat(it.lines) - 0.4)
                if w > 0 { size = min(max(20 * filled / w, byHeight * 0.6), byHeight * 1.1) }
            } else if it.text.count >= 4 {
                // Width is steadier than height (which swings with ascenders and descenders).
                let w = (it.text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 20)]).width
                if w > 0 { size = min(max(20 * it.rect.width / w, byHeight * 0.6), byHeight * 1.4) }
            }
            it.size = max(7, size)
            return it
        }
        // Snap single lines only (paragraphs keep their own estimate), in clusters that stay
        // within 12% of their smallest member so a chain of steps can't drift upward.
        let sizes = out.filter { $0.lines == 1 }.compactMap(\.size).sorted()
        var clusters: [[CGFloat]] = []
        for s in sizes {
            if let first = clusters.last?.first, s <= first * 1.12 { clusters[clusters.count - 1].append(s) } else { clusters.append([s]) }
        }
        for i in out.indices where out[i].lines == 1 {
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

    /// Frame (AppKit coordinates) of the frontmost window of `app`, from the window server.
    static func frontWindowFrame(of app: NSRunningApplication?) -> CGRect? {
        guard let pid = app?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        // The frontmost window that is a real window: in full screen the title bar is a
        // separate thin window listed first, so skip anything too small to be the content.
        for w in list where (w[kCGWindowOwnerPID as String] as? pid_t) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
            if let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b as CFDictionary),
               r.width >= 120, r.height >= 120 {
                return Coords.fromQuartz(r)
            }
        }
        return nil
    }

    static var frontApp: NSRunningApplication? {
        let a = NSWorkspace.shared.frontmostApplication
        return a?.processIdentifier == getpid() ? nil : a
    }
}
