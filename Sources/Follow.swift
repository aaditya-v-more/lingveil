import AppKit
import NaturalLanguage
import ScreenCaptureKit

/// Keeps a translation in the app while you scroll, click and type, the way a Pixel phone
/// translates inside apps. A capture stream at one pixel per point (frames arrive only when
/// something changed) shows how far each part of the screen moved; translated blocks move
/// with their text at once, blocks whose text went away are hidden, and when the screen is
/// still again it is read and translated again. Repeated text comes from the translation
/// cache, so only newly revealed text costs anything.
@MainActor
final class Follower: NSObject, SCStreamOutput, SCStreamDelegate {
    private weak var window: OverlayWindow?
    private let screen: NSScreen
    private let area: CGRect
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "lingveil.follow", qos: .userInteractive)
    nonisolated let tracker: MotionTracker
    private var lastChange = Date.distantPast
    private var dirty = false
    private var loop: Task<Void, Never>?
    private(set) var running = false
    private var settle: Timer?
    private var exact: [CGFloat] = [], previous: [CGFloat] = [], hidden = Set<Int>()
    private var previousTime: Double = 0
    private var reading = 0
    private var shownSequence = -1   // the frame the blocks on screen were read from
    /// What is being followed: the translated blocks, then areas already read that need no
    /// translation (code, numbers, images without text), all as of the current reference.
    private var blocks: [Block] = []
    private var known: [CGRect] = []          // top-down points within the area
    /// What each followed block's original text looked like (from the frame it was read
    /// in), and blocks that scrolled away, kept with that picture. When text scrolls back
    /// into view and looks the same, its block comes back at once: no reading, no translating.
    private struct Look { let pixels: [UInt8]; let w: Int; let h: Int; let rect: CGRect; let rows: [Float]; let contrast: Float }
    private var looks: [Look?] = []
    private var memory: [(block: Block, look: Look)] = []
    private var lastFullRead = Date()
    private var lastRecall = Date.distantPast
    private var recalling = false
    private var partialSinceFull = false
    /// From setting a layer's position to it being on screen.
    private static let predicts = ProcessInfo.processInfo.environment["LINGVEIL_NOPREDICT"] == nil
    private static let drawDelay = (Double(ProcessInfo.processInfo.environment["LINGVEIL_LEAD_MS"] ?? "") ?? 4) / 1000
    private var speed: CGFloat = 0   // points per second, fastest visible block
    /// No new frame for this long means the screen has stopped moving: a few refreshes, so
    /// a slow drag that skips a frame doesn't count as stopping.
    private static let stillAfter: TimeInterval = 0.06
    var onBusy: ((Bool) -> Void)?
    /// Tests only: follow one window directly (captured even when covered) instead of the
    /// screen, with its content starting `windowTop` points below the window's top edge.
    var testWindow: (SCWindow, windowTop: CGFloat)?
    /// The app whose accessibility text is read (tests follow a window with none).
    var app: () -> NSRunningApplication? = { Pipeline.frontApp }

    init(window: OverlayWindow, screen: NSScreen, area: CGRect) {
        self.window = window; self.screen = screen; self.area = area
        tracker = MotionTracker(scale: max(1, Int(screen.backingScaleFactor.rounded())))
    }

    /// Starts watching and returns once the first frame is in.
    func start() async {
        do {
            let cfg = SCStreamConfiguration()
            let filter: SCContentFilter
            if let (w, top) = testWindow {
                filter = SCContentFilter(desktopIndependentWindow: w)
                cfg.sourceRect = CGRect(x: 0, y: top, width: area.width, height: area.height)
            } else {
                filter = try await Capture.filter(for: screen).0
                cfg.sourceRect = Capture.localRect(area, on: screen)
            }
            // Full resolution: the same frames are read (OCR) when text needs translating, so
            // what is translated always lines up with what is being tracked.
            cfg.width = Int(area.width) * tracker.scale; cfg.height = Int(area.height) * tracker.scale
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            cfg.queueDepth = 5
            cfg.showsCursor = false
            cfg.pixelFormat = kCVPixelFormatType_32BGRA
            let s = SCStream(filter: filter, configuration: cfg, delegate: self)
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await s.startCapture()
            stream = s
            running = true
            for _ in 0..<40 where !tracker.hasFrame { try? await Task.sleep(for: .milliseconds(25)) }
            dirty = true   // the first frame may have arrived before this was running
            loop = Task { await refreshLoop() }
            prefetch()
        } catch { Debug.log("follow could not start: \(error.localizedDescription)") }
    }

    func stop() {
        running = false
        loop?.cancel(); loop = nil
        settle?.invalidate(); settle = nil
        let s = stream; stream = nil
        Task { try? await s?.stopCapture() }
        tracker.reset()
    }

    /// Shows `blocks`, read from the frame `token` was taken at. If the screen has moved
    /// since, they are moved to where their text is now before they appear.
    @discardableResult
    func adopt(_ blocks: [Block], known: [CGRect] = [], _ token: MotionTracker.Token) -> Bool {
        guard running, let w = window else { return false }
        let rects = blocks.map { local($0.item.rect) }
        guard let catchUp = tracker.setReference(token, rects + known) else { return false }
        // Blocks that are going away keep their look, to come back if their text does.
        let staying = Set(blocks.map(\.item.text))
        for (i, b) in self.blocks.enumerated() where !staying.contains(b.item.text) {
            if i < looks.count, let l = looks[i] {
                memory.removeAll { $0.block.item.text == b.item.text }
                memory.append((b, l))
            }
        }
        if memory.count > 300 { memory.removeFirst(memory.count - 300) }
        looks = rects.map { look(token, $0) }
        self.blocks = blocks; self.known = known
        if languages == nil, !blocks.isEmpty { learnLanguages(blocks.map(\.item)) }
        previous = []; previousTime = 0
        if let m = catchUp, let sh = m.shifts {
            // Read from an older frame: put the blocks where their text is now before they appear.
            exact = sh.prefix(blocks.count).map { -CGFloat($0) }; hidden = m.hidden.filter { $0 < blocks.count }
            w.view.show(blocks, shifts: exact, hidden: hidden)
        } else {
            exact = []; hidden = []
            w.view.blocks = blocks
            dirty = false
        }
        return true
    }

    /// A block's pixels in frame `token` (top-down points), if it's wholly in view.
    private func look(_ token: MotionTracker.Token, _ r: CGRect) -> Look? {
        let x0 = Int(r.minX.rounded()), y0 = Int(r.minY.rounded()), w = Int(r.width.rounded()), h = Int(r.height.rounded())
        guard x0 >= 0, y0 >= 0, w >= 8, h >= 6, x0 + w < token.w, y0 + h <= token.h else { return nil }
        var px = [UInt8](repeating: 0, count: w * h)
        token.luma.withUnsafeBufferPointer { l in
            for y in 0..<h { for x in 0..<w { px[y * w + x] = l[(y0 + y) * token.w + x0 + x] } }
        }
        let rows = (0..<h).map { y in Float((0..<(w - 1)).reduce(0) { $0 + abs(Int(px[y * w + $1 + 1]) - Int(px[y * w + $1])) }) }
        let mean = px.reduce(0) { $0 + Int($1) } / px.count
        let contrast = Float(px.reduce(0) { $0 + abs(Int($1) - mean) }) / Float(px.count)
        guard contrast > 3 else { return nil }
        return Look(pixels: px, w: w, h: h, rect: CGRect(x: x0, y: y0, width: w, height: h), rows: rows, contrast: contrast)
    }

    /// Remembered blocks whose text is back in view inside `strips` of frame `token`,
    /// placed where it is now. Each is found by sliding its picture up and down over the
    /// strip (same left edge: scrolling is vertical) and must match closely.
    nonisolated private static func recall(_ strips: [CGRect], _ token: MotionTracker.Token, _ memory: [(block: Block, look: Look)], area: CGRect) -> [(Int, Block)] {
        func global(_ r: CGRect) -> CGRect { CGRect(x: area.minX + r.minX, y: area.maxY - r.maxY, width: r.width, height: r.height) }
        var found: [(Int, Block)] = []
        var rowCache: [Int: Float] = [:]
        let lw = token.w
        token.luma.withUnsafeBufferPointer { l in
            for (k, m) in memory.enumerated().reversed() {
                let lk = m.look
                guard let strip = strips.first(where: { $0.minX <= lk.rect.minX + 4 && $0.maxX >= lk.rect.maxX - 4 }) else { continue }
                let lo = max(0, Int(strip.minY) - lk.h / 3), hi = min(token.h - lk.h, Int(strip.maxY) - lk.h * 2 / 3)
                guard lo <= hi else { continue }
                let x0 = Int(lk.rect.minX)
                func rowEnergy(_ y: Int) -> Float {
                    let key = y &* 100_003 &+ x0 &* 7 &+ lk.w
                    if let v = rowCache[key] { return v }
                    var e = 0
                    for x in x0..<(x0 + lk.w - 1) { e += abs(Int(l[y * lw + x + 1]) - Int(l[y * lw + x])) }
                    rowCache[key] = Float(e)
                    return Float(e)
                }
                // Cheap first pass on row profiles, then the picture itself at the best spots.
                let energy = max(1, lk.rows.reduce(0, +))
                var cands: [(Float, Int)] = []
                for y in lo...hi {
                    var d: Float = 0
                    for r in 0..<lk.h { d += abs(lk.rows[r] - rowEnergy(y + r)) }
                    cands.append((d / energy, y))
                }
                cands.sort { $0.0 < $1.0 }
                for (pd, y) in cands.prefix(3) where pd < 0.25 {
                    var diff = 0, n = 0
                    for r in 0..<lk.h {
                        var x = 0
                        while x < lk.w { diff += abs(Int(lk.pixels[r * lk.w + x]) - Int(l[(y + r) * lw + x0 + x])); n += 1; x += 2 }
                    }
                    if Float(diff) / Float(max(1, n)) / max(lk.contrast, 4) < 0.15 {
                        var b = m.block
                        b.item.rect = global(CGRect(x: lk.rect.minX, y: CGFloat(y), width: lk.rect.width, height: lk.rect.height))
                        found.append((k, b))
                        break
                    }
                }
            }
        }
        return found
    }

    /// What is followed now, moved to where it is in frame `token`.
    private func carried(_ token: MotionTracker.Token) -> ([Block], [CGRect]) {
        var kept: [Block] = [], keptKnown: [CGRect] = []
        for (i, b) in blocks.enumerated() where i < token.shifts.count && !token.hidden.contains(i) {
            var moved = b
            moved.item.rect.origin.y -= CGFloat(token.shifts[i])
            kept.append(moved)
        }
        for (k, r) in known.enumerated() where blocks.count + k < token.shifts.count && !token.hidden.contains(blocks.count + k) {
            keptKnown.append(r.offsetBy(dx: 0, dy: CGFloat(token.shifts[blocks.count + k])))
        }
        return (kept, keptKnown)
    }

    /// Global AppKit rect -> top-down points within the area, and back.
    func localRect(_ r: CGRect) -> CGRect { local(r) }
    private func local(_ r: CGRect) -> CGRect { CGRect(x: r.minX - area.minX, y: area.maxY - r.maxY, width: r.width, height: r.height) }
    private func global(_ r: CGRect) -> CGRect { CGRect(x: area.minX + r.minX, y: area.maxY - r.maxY, width: r.width, height: r.height) }

    /// Areas of `items` that were read but produced no block (left as is): followed too, so
    /// they aren't read again.
    static func untranslated(_ items: [TextItem], _ blocks: [Block]) -> [CGRect] {
        items.filter { it in
            let a = it.rect.width * it.rect.height
            return !blocks.contains { b in let o = b.item.rect.intersection(it.rect); return !o.isNull && o.width * o.height > a * 0.7 }
        }.map(\.rect)
    }

    /// The page's languages, learned from the first full read, so later reads can tell the
    /// recognizer instead of making it work them out.
    private var languages: [String]?
    private func learnLanguages(_ items: [TextItem]) {
        let r = NLLanguageRecognizer()
        r.processString(items.map(\.text).joined(separator: "\n"))
        var langs = r.languageHypotheses(withMaximum: 3).filter { $0.value > 0.15 }.sorted { $0.value > $1.value }.map(\.key.rawValue)
        if !langs.contains("en") { langs.append("en") }   // UI words, names, code
        languages = langs
    }

    /// Reads several strips of `snap` (top-down points) in one go: stacked into one image,
    /// since each separate request has a fixed cost.
    private func read(_ strips: [CGRect], in snap: Snapshot) async -> [TextItem] {
        let s = snap.scale, gap = 24
        let px = strips.map { r in CGRect(x: r.minX * s, y: r.minY * s, width: r.width * s, height: r.height * s).integral
            .intersection(CGRect(x: 0, y: 0, width: snap.pixels.width, height: snap.pixels.height)) }.filter { $0.width >= 8 && $0.height >= 8 }
        guard !px.isEmpty, let W = px.map({ Int($0.width) }).max() else { return [] }
        let H = px.reduce(0) { $0 + Int($1.height) } + gap * (px.count - 1)
        guard let out = PixelBuffer(width: W, height: H) else { return [] }
        var offsets: [Int] = []
        var y = 0
        for (k, r) in px.enumerated() {
            offsets.append(y)
            let rw = Int(r.width)
            for row in 0..<Int(r.height) {
                let dst = out.base + (y + row) * out.bytesPerRow
                memcpy(dst, snap.pixels.base + (Int(r.minY) + row) * snap.pixels.bytesPerRow + Int(r.minX) * 4, rw * 4)
                // Pad to the full width with the row's last pixel (blends in, adds no edges).
                for x in rw..<W { memcpy(dst + x * 4, dst + (rw - 1) * 4, 4) }
            }
            y += Int(r.height)
            if k < px.count - 1 {
                for row in 0..<gap { memcpy(out.base + (y + row) * out.bytesPerRow, out.base + (y - 1) * out.bytesPerRow, out.bytesPerRow) }
                y += gap
            }
        }
        let found = await OCRHelper.shared.recognize(out, fast: false, minHeight: 7 * s, languages: languages)
        var lines: [TextItem] = []
        for (t, b) in found {
            // Normalized, bottom-left origin -> pixels from the top of the stack.
            let top = (1 - b.maxY) * CGFloat(H), cy = (1 - b.midY) * CGFloat(H)
            guard let k = offsets.indices.last(where: { CGFloat(offsets[$0]) <= cy }), cy < CGFloat(offsets[k]) + px[k].height else { continue }
            let r = CGRect(x: (px[k].minX + b.minX * CGFloat(W)) / s, y: (px[k].minY + top - CGFloat(offsets[k])) / s,
                           width: b.width * CGFloat(W) / s, height: b.height * CGFloat(H) / s)
            lines.append(TextItem(text: t, rect: global(r), lines: 1))
        }
        return Pipeline.estimateSizes(OCR.paragraphs(lines))
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = sb.imageBuffer else { return }
        // When the frame was on screen, to work out how far things have moved since.
        var shown = CACurrentMediaTime()
        if let mach = info[.displayTime] as? UInt64 {
            var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
            shown = Double(mach) * Double(tb.numer) / Double(tb.denom) / 1e9
        }
        let t0 = CACurrentMediaTime()
        guard let motion = tracker.frame(pb, time: shown) else { return }
        let t1 = CACurrentMediaTime()
        Task { @MainActor in
            Debug.log(String(format: "frame track %.1f ms, %.1f ms after shown, main %.1f ms later", (t1 - t0) * 1000, (t1 - shown) * 1000, (CACurrentMediaTime() - t1) * 1000))
            self.changed(motion)
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Debug.log("follow stream stopped: \(error.localizedDescription)")
    }

    private func changed(_ m: MotionTracker.Motion) {
        guard running else { return }
        lastChange = Date()
        dirty = true
        if m.shifts != nil, m.reference == tracker.referenceID { apply(m, predict: true) }
    }

    /// Moves the blocks to the measured positions. While scrolling, the frame that was
    /// measured is already a little old by the time the overlay is shown, so blocks are
    /// put a little further along their way (the last frame's move); when frames stop
    /// coming, they settle on the measured spot.
    private func apply(_ m: MotionTracker.Motion, predict: Bool) {
        guard let all = m.shifts, let view = window?.view else { return }
        // Image rows grow downward; the view's y grows upward. Known areas come after the
        // blocks and aren't shown.
        let s = all.prefix(blocks.count)
        let now = s.map { -CGFloat($0) }
        let m = MotionTracker.Motion(reference: m.reference, shifts: Array(s), hidden: m.hidden.filter { $0 < blocks.count }, time: m.time)
        var shown = now
        let dt = m.time - previousTime
        var fastest: CGFloat = 0
        if previous.count == now.count, dt > 0.004, dt < 0.1 {
            // Each block's speed, and how old the frame is by the time this is on screen
            // (capture and processing, plus about half a refresh until it's drawn).
            let lead = CGFloat(min(0.06, max(0, CACurrentMediaTime() - m.time + Self.drawDelay)))
            for i in now.indices where !m.hidden.contains(i) {
                let v = (now[i] - previous[i]) / CGFloat(dt)
                fastest = max(fastest, abs(v))
                if predict, Self.predicts { shown[i] += max(-250, min(250, v * lead)) }
            }
        }
        speed = fastest
        previous = now; previousTime = m.time; exact = now; hidden = m.hidden
        view.move(shown, hidden: m.hidden)
        settle?.invalidate()
        if shown != now {
            settle = Timer.scheduledTimer(withTimeInterval: 0.045, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.running, self.exact.count == now.count else { return }
                    self.speed = 0
                    self.window?.view.move(self.exact, hidden: self.hidden)
                }
            }
        }
    }

    /// Reads and translates whatever is new, as soon as the screen stops moving. While it
    /// moves, nothing is read, recalled or added: the only work is keeping what is already
    /// translated on its text, so scrolling stays smooth. Only the parts of the frame that
    /// aren't already followed are read (text scrolled into view, text that changed), so
    /// reading takes tens of milliseconds instead of the whole window's hundreds. Once
    /// things have been still for a second, the whole window is read once more with
    /// accessibility (exact text and fonts).
    private func refreshLoop() async {
        while running, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(30))
            let stillFor = Date().timeIntervalSince(lastChange)
            guard stillFor > Self.stillAfter else { continue }
            let polish = !dirty && partialSinceFull && stillFor > 1.0 && Date().timeIntervalSince(lastFullRead) > 1.0
            guard dirty || polish else { continue }
            // Text back in view that was translated before: put it back without reading it.
            // Whatever is still unread after that is read below.
            if dirty, !polish, !recalling, !memory.isEmpty, shownSequence >= 0, Date().timeIntervalSince(lastRecall) > 0.08,
               let token = tracker.begin(), token.reference == tracker.referenceID {
                lastRecall = Date()
                recalling = true
                let strips = unread(token, edges: true), mem = memory
                // Matching runs off the main thread so following never stalls.
                Task.detached(priority: .userInitiated) { [area] in
                    let back = Self.recall(strips, token, mem, area: area)
                    while await MainActor.run(body: { self.running && Date().timeIntervalSince(self.lastChange) <= Self.stillAfter }) {
                        try? await Task.sleep(for: .milliseconds(8))
                    }
                    await MainActor.run {
                        self.recalling = false
                        guard !back.isEmpty, self.running, token.reference == self.tracker.referenceID, token.sequence > self.shownSequence else { return }
                        let (kept, keptKnown) = self.carried(token)
                        let ids = Set(back.map(\.0))
                        self.memory = self.memory.enumerated().filter { !ids.contains($0.offset) || $0.offset >= mem.count }.map(\.element)
                        if self.adopt(kept + back.map(\.1), known: keptKnown, token) {
                            self.shownSequence = token.sequence
                            self.dirty = true   // read whatever is still unread
                            Debug.log("follow recalled \(back.count) blocks")
                        }
                    }
                }
            }
            guard reading == 0 else { continue }
            dirty = false
            guard let token = tracker.begin(), let pixels = token.pixels else { Debug.log("follow: no frame to read"); continue }
            let snap = Snapshot(pixels: pixels, frame: area, scale: CGFloat(tracker.scale))
            // Read only what's new, unless nothing is followed yet, it's time for the full
            // read, or most of the window is new anyway.
            var strips: [CGRect]? = nil
            if !polish, shownSequence >= 0, token.reference == tracker.referenceID {
                strips = unread(token, edges: false)
                if let st = strips, st.reduce(0, { $0 + $1.width * $1.height }) > area.width * area.height * 0.6 { strips = nil }
            }
            if strips?.isEmpty == true { continue }   // everything in view is already followed
            let full = strips == nil
            reading += 1
            onBusy?(true)
            Task {
                defer {
                    reading -= 1
                    onBusy?(reading > 0)
                }
                let t0 = Date()
                let app = self.app()
                let target = Language.named(Prefs.target)
                var items: [TextItem] = []
                if let strips {
                    items = await read(strips, in: snap)
                } else {
                    items = await Pipeline.items(in: snap, app: app)
                }
                let tOCR = Date().timeIntervalSince(t0)
                if full { learnLanguages(items) }
                let fresh: [Block]
                do { fresh = try await Pipeline.blocks(for: items, in: snap, to: target, focus: Pipeline.frontWindowFrame(of: app)) } catch {
                    Debug.log("follow refresh failed: \(error.localizedDescription) (\(items.count) items)")
                    return
                }
                // Scrolling started again while this was read: keep it until it stops, then
                // show it where its text is by then.
                while running, Date().timeIntervalSince(lastChange) <= Self.stillAfter { try? await Task.sleep(for: .milliseconds(8)) }
                guard running, token.sequence > shownSequence else { return }
                var newKnown = Self.untranslated(items, fresh).map(local)
                if let strips {
                    // Strips with nothing readable in them (pictures, icons) are known too.
                    newKnown += strips.filter { r in !items.contains { local($0.rect).intersects(r) } }
                }
                var all = fresh, allKnown = newKnown
                if !full {
                    // Keep everything already followed, moved to where it is in this frame.
                    guard token.reference == tracker.referenceID else { dirty = true; return }
                    let (kept, keptKnown) = carried(token)
                    for moved in kept where !fresh.contains(where: { $0.item.rect.intersection(moved.item.rect).width * $0.item.rect.intersection(moved.item.rect).height > moved.item.rect.width * moved.item.rect.height * 0.3 }) {
                        all.append(moved)
                    }
                    allKnown += keptKnown
                }
                Debug.log(String(format: "follow %d new blocks (%d kept) from %@ in %.0f ms (reading %.0f)", fresh.count, all.count - fresh.count,
                                 strips.map { "\($0.count) strips, \(Int($0.reduce(0) { $0 + $1.height })) pt tall" } ?? "whole window", Date().timeIntervalSince(t0) * 1000, tOCR * 1000))
                if adopt(all, known: allKnown, token) {
                    shownSequence = token.sequence
                    if full { lastFullRead = Date(); partialSinceFull = false } else { partialSinceFull = true }
                } else { dirty = true }
            }
        }
    }

    /// The parts of frame `token` with something on them that nothing followed covers:
    /// horizontal strips (in top-down points) to read. `edges`: leave out text cut by the
    /// top and bottom edges while scrolling; it will be whole in a moment.
    private func unread(_ token: MotionTracker.Token, edges: Bool) -> [CGRect] {
        let w = token.w, h = token.h, cw = 32, ch = 8
        let cols = (w + cw - 1) / cw, rows = (h + ch - 1) / ch
        var covered = [Bool](repeating: false, count: cols * rows)
        let rects = blocks.map { local($0.item.rect) } + known
        for (i, r) in rects.enumerated() where i < token.shifts.count && !token.hidden.contains(i) {
            let m = r.offsetBy(dx: 0, dy: CGFloat(token.shifts[i])).insetBy(dx: -3, dy: -3)
            let c0 = max(0, Int(m.minX) / cw), c1 = min(cols - 1, Int(m.maxX) / cw)
            let r0 = max(0, Int(m.minY) / ch), r1 = min(rows - 1, Int(m.maxY) / ch)
            guard c0 <= c1, r0 <= r1 else { continue }
            for rr in r0...r1 {
                let cy = CGFloat(rr * ch + ch / 2)
                guard cy >= m.minY, cy <= m.maxY else { continue }
                for cc in c0...c1 where CGFloat(cc * cw + cw / 2) >= m.minX && CGFloat(cc * cw + cw / 2) <= m.maxX { covered[rr * cols + cc] = true }
            }
        }
        // A cell needs reading if it has edges in it (text, pictures) and isn't covered.
        var need = [Bool](repeating: false, count: cols * rows)
        token.luma.withUnsafeBufferPointer { l in
            for rr in 0..<rows {
                if edges, rr * ch < 10 || (rr + 1) * ch > h - 10 { continue }
                for cc in 0..<cols where !covered[rr * cols + cc] {
                    var busy = 0
                    let y1 = min(h, rr * ch + ch), x1 = min(w - 1, cc * cw + cw)
                    var y = rr * ch
                    while y < y1 {
                        for x in (cc * cw)..<x1 where abs(Int(l[y * w + x + 1]) - Int(l[y * w + x])) > 28 { busy += 1 }
                        y += 2
                    }
                    need[rr * cols + cc] = busy >= 4
                }
            }
        }
        // Rows of needed cells, joined into strips (one empty row may sit between).
        var strips: [CGRect] = []
        var start = -1, gap = 0, minC = cols, maxC = -1
        func close(_ end: Int) {
            guard start >= 0 else { return }
            let r = CGRect(x: max(0, minC * cw - 8), y: max(0, start * ch - 4), width: 0, height: 0)
            let x1 = min(w, (maxC + 1) * cw + 8), y1 = min(h, (end + 1) * ch + 4)
            var s = CGRect(x: r.minX, y: r.minY, width: CGFloat(x1) - r.minX, height: CGFloat(y1) - r.minY)
            if s.height < 18 { s = s.insetBy(dx: 0, dy: -(18 - s.height) / 2).intersection(CGRect(x: 0, y: 0, width: w, height: h)) }
            strips.append(s)
            start = -1; minC = cols; maxC = -1
        }
        for rr in 0..<rows {
            let row = (0..<cols).filter { need[rr * cols + $0] }
            if row.isEmpty {
                if start >= 0 { gap += 1; if gap > 1 { close(rr - gap) ; gap = 0 } }
                continue
            }
            if start < 0 { start = rr }
            gap = 0
            minC = min(minC, row.first!); maxC = max(maxC, row.last!)
        }
        close(rows - 1 - gap)
        return strips
    }

    /// Translates text just above and below the window ahead of time, where the app reports
    /// it (web pages, documents), so it is ready the moment it scrolls into view. Skipped
    /// for models on this Mac, where it would cost real work for text that may never be seen.
    private func prefetch() {
        guard ![.local, .ollama].contains(Prefs.engine), let app = app() else { return }
        let around = area.insetBy(dx: 0, dy: -area.height * 2)
        let target = Language.named(Prefs.target)
        Task.detached(priority: .utility) {
            let texts = AXText.items(app: app, within: around, budget: 1.0, beyondWindow: true)
                .map(\.text).filter { $0.count > 3 && Translation.cached($0, to: target) == nil }
            let todo = Array(NSOrderedSet(array: texts).array as! [String]).prefix(150)
            guard !todo.isEmpty else { return }
            _ = try? await Translation.translate(Array(todo), to: target)
            Debug.log("follow prefetched \(todo.count) texts")
        }
    }

    /// Kept for the first translation, which comes from its own capture.
    func refreshWhenStill() { dirty = true }
}

/// Works out, from frame to frame, where each translated block's text has gone. Runs on
/// the capture queue; frames are kept as one byte of brightness per point.
final class MotionTracker: @unchecked Sendable {
    struct Token {
        var sequence: Int { changes }
        fileprivate let changes: Int; fileprivate let luma: [UInt8]; fileprivate let w: Int; fileprivate let h: Int; let pixels: PixelBuffer?
        /// The reference the boxes below belong to, each box's move in this frame (rows,
        /// down is positive) and the boxes that weren't found in it.
        let reference: Int; let shifts: [Int]; let hidden: Set<Int>
    }
    /// `time`: when the frame was on screen (CACurrentMediaTime seconds).
    struct Motion { let reference: Int; let shifts: [Int]?; let hidden: Set<Int>; var time = CACurrentMediaTime() }

    private struct Box { let x0, x1, y0, y1: Int; let contrast: Float }

    let scale: Int
    init(scale: Int) { self.scale = scale }

    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var w = 0, h = 0
    private var luma: [UInt8] = []
    private var print: [UInt8] = []
    private var changes = 0
    private var refID = 0
    private var ref: [UInt8] = []
    private var refSmall: [UInt8] = []
    private var boxes: [Box] = []
    private var last: [Int] = []
    private var lastHidden = Set<Int>()
    private var lastBand: [Int] = []
    private static let bandCount = 4, small = 8

    var hasFrame: Bool { lock.withLock { !luma.isEmpty } }
    var referenceID: Int { lock.withLock { refID } }

    func reset() { lock.withLock { luma = []; print = []; boxes = []; ref = []; latest = nil; refID += 1 } }

    /// The current frame: its brightness (to follow from) and its pixels (to read text from).
    func begin() -> Token? {
        lock.withLock {
            guard !luma.isEmpty else { return nil }
            var px: PixelBuffer?
            if let pb = latest {
                CVPixelBufferLockBaseAddress(pb, .readOnly)
                let pw = CVPixelBufferGetWidth(pb), ph = CVPixelBufferGetHeight(pb), row = CVPixelBufferGetBytesPerRow(pb)
                if let src = CVPixelBufferGetBaseAddress(pb), let p = PixelBuffer(width: pw, height: ph) {
                    for y in 0..<ph { memcpy(p.base + y * p.bytesPerRow, src + y * row, pw * 4) }
                    px = p
                }
                CVPixelBufferUnlockBaseAddress(pb, .readOnly)
            }
            return Token(changes: changes, luma: luma, w: w, h: h, pixels: px, reference: refID, shifts: last, hidden: lastHidden)
        }
    }

    /// Makes `rects` (top-down points within the area, as they were in frame `t`) the blocks
    /// to follow. Returns nil if that can't be done (the area changed size); otherwise, if
    /// the screen moved since `t`, where the blocks are now.
    func setReference(_ t: Token, _ rects: [CGRect]) -> Motion?? {
        lock.withLock {
            guard !t.luma.isEmpty, t.w == w, t.h == h else { return nil }
            ref = t.luma
            refSmall = Self.shrink(ref, w, h)
            boxes = rects.map { r in
                let x0 = max(0, Int(r.minX)), x1 = min(w, Int(r.maxX)), y0 = max(0, Int(r.minY)), y1 = min(h, Int(r.maxY))
                return Box(x0: x0, x1: max(x0, x1), y0: y0, y1: max(y0, y1), contrast: Self.contrast(ref, w, x0, max(x0, x1), y0, max(y0, y1)))
            }
            last = Array(repeating: 0, count: rects.count)
            lastHidden = []
            lastBand = Array(repeating: 0, count: Self.bandCount)
            refID += 1
            return .some(t.changes == changes ? nil : track(luma))
        }
    }

    /// nil when the frame looks the same as the previous one.
    func frame(_ pb: CVPixelBuffer, time: Double) -> Motion? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let pw = CVPixelBufferGetWidth(pb), ph = CVPixelBufferGetHeight(pb), row = CVPixelBufferGetBytesPerRow(pb)
        let fp = Live.fingerprint(base, pw, ph, row)
        lock.lock(); defer { lock.unlock() }
        guard Live.differs(fp, print) else { return nil }
        print = fp
        // One brightness sample per point is plenty to follow motion.
        let fw = pw / scale, fh = ph / scale
        var l = [UInt8](repeating: 0, count: fw * fh)
        let p = base.assumingMemoryBound(to: UInt8.self)
        l.withUnsafeMutableBufferPointer { out in
            for y in 0..<fh {
                let r = p + y * scale * row, o = y * fw
                for x in 0..<fw { let q = r + x * scale * 4; out[o + x] = UInt8((Int(q[0]) + 2 * Int(q[1]) + Int(q[2])) >> 2) }
            }
        }
        if fw != w || fh != h { w = fw; h = fh; boxes = []; ref = [] }
        luma = l
        latest = pb
        changes += 1
        guard !boxes.isEmpty else { return Motion(reference: refID, shifts: nil, hidden: [], time: time) }
        var m = track(l)
        m.time = time
        return m
    }

    private func track(_ l: [UInt8]) -> Motion {

        // How far each vertical band of the screen scrolled (coarse on a small copy, then
        // to the point), then, per block, which of those moves (or none) its text matches.
        let cur = Self.shrink(l, w, h)
        let sw = w / Self.small, sh = h / Self.small
        var candidates = Set([0])
        for b in 0..<Self.bandCount {
            let x0 = b * sw / Self.bandCount, x1 = (b + 1) * sw / Self.bandCount
            var coarse = (Float.infinity, 0)
            for d in -(sh * 7 / 10)...(sh * 7 / 10) {
                // Scrolling is continuous: among similar matches (repeated text), prefer the one
                // nearest the last move.
                let s = Self.sad(refSmall, cur, sw, sh, x0, x1, 0, sh, d, step: 1, minRows: max(6, sh / 4)) * Self.near(d * Self.small, lastBand[b])
                if s < coarse.0 { coarse = (s, d) }
            }
            guard coarse.0 < .infinity else { continue }
            var fine = (Float.infinity, 0)
            let fx0 = x0 * Self.small, fx1 = x1 * Self.small
            for d in (coarse.1 * Self.small - Self.small)...(coarse.1 * Self.small + Self.small) {
                let s = Self.sad(ref, l, w, h, fx0, fx1, 0, h, d, step: 3, minRows: h / 4)
                if s < fine.0 { fine = (s, d) }
            }
            if fine.0 < .infinity { candidates.insert(fine.1); lastBand[b] = fine.1 }
        }
        var shifts = [Int](repeating: 0, count: boxes.count)
        var hidden = Set<Int>()
        for (i, b) in boxes.enumerated() {
            var best = (Float.infinity, 0)
            for d in candidates.union([last[i]]) {
                // Mostly scrolled out of view: hide it rather than guess.
                let s = Self.blockScore(ref, l, w, h, b, d) / max(b.contrast, 4) * Self.near(d, last[i])
                if s < best.0 { best = (s, d) }
            }
            if best.0 < 0.35 { shifts[i] = best.1; last[i] = best.1 } else { hidden.insert(i); shifts[i] = last[i] }
        }
        lastHidden = hidden
        return Motion(reference: refID, shifts: shifts, hidden: hidden)
    }

    /// How well a block matches at move `d`, judged in eight side-by-side pieces and
    /// ignoring the worst ones: a scroll bar fading in, the pointer or a blinking caret over
    /// part of a paragraph shouldn't make it look like the text went away.
    private static func blockScore(_ a: [UInt8], _ b: [UInt8], _ w: Int, _ h: Int, _ box: Box, _ d: Int) -> Float {
        let minRows = max(1, (box.y1 - box.y0) * 2 / 3)
        let width = box.x1 - box.x0
        let pieces = max(1, min(8, width / 24))
        var scores: [Float] = []
        for k in 0..<pieces {
            let x0 = box.x0 + k * width / pieces, x1 = box.x0 + (k + 1) * width / pieces
            scores.append(sad(a, b, w, h, x0, x1, box.y0, box.y1, d, step: 2, minRows: minRows))
        }
        scores.sort()
        return scores[min(scores.count - 1, scores.count * 6 / 10)]
    }

    private static func near(_ d: Int, _ last: Int) -> Float { 1 + Float(abs(d - last)) / 300 }

    /// Mean brightness difference between `a` in the given box and `b` moved down by `d`.
    private static func sad(_ a: [UInt8], _ b: [UInt8], _ w: Int, _ h: Int, _ x0: Int, _ x1: Int, _ y0: Int, _ y1: Int,
                            _ d: Int, step: Int, minRows: Int) -> Float {
        let lo = max(y0, -d), hi = min(y1, h - d)
        guard hi - lo >= minRows, x1 > x0 else { return .infinity }
        var s = 0, n = 0
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                for y in lo..<hi {
                    let oa = y * w, ob = (y + d) * w
                    var x = x0
                    while x < x1 { s += abs(Int(pa[oa + x]) - Int(pb[ob + x])); n += 1; x += step }
                }
            }
        }
        return n == 0 ? .infinity : Float(s) / Float(n)
    }

    /// How much the box varies from its own average: text on a background is high.
    private static func contrast(_ a: [UInt8], _ w: Int, _ x0: Int, _ x1: Int, _ y0: Int, _ y1: Int) -> Float {
        guard x1 > x0, y1 > y0 else { return 0 }
        var sum = 0, n = 0
        for y in y0..<y1 { for x in x0..<x1 { sum += Int(a[y * w + x]); n += 1 } }
        let mean = sum / n
        var dev = 0
        for y in y0..<y1 { for x in x0..<x1 { dev += abs(Int(a[y * w + x]) - mean) } }
        return Float(dev) / Float(n)
    }

    /// An 8x smaller copy (block averages), for the coarse search.
    private static func shrink(_ a: [UInt8], _ w: Int, _ h: Int) -> [UInt8] {
        let sw = w / small, sh = h / small
        var out = [UInt8](repeating: 0, count: max(0, sw * sh))
        for y in 0..<sh {
            for x in 0..<sw {
                var s = 0
                for yy in 0..<small { let o = (y * small + yy) * w + x * small; for xx in 0..<small { s += Int(a[o + xx]) } }
                out[y * sw + x] = UInt8(s / (small * small))
            }
        }
        return out
    }
}
