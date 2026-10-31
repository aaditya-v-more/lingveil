import AppKit
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
    private var lastRefresh = Date()
    private var dirty = false
    private var loop: Task<Void, Never>?
    private(set) var running = false
    private var settle: Timer?
    private var exact: [CGFloat] = [], previous: [CGFloat] = [], hidden = Set<Int>()
    private var previousTime: Double = 0
    private var reading = 0, stillReading = false
    private var shownSequence = -1   // the frame the blocks on screen were read from
    /// From setting a layer's position to it being on screen.
    private static let predicts = ProcessInfo.processInfo.environment["LINGVEIL_NOPREDICT"] == nil
    private static let drawDelay = (Double(ProcessInfo.processInfo.environment["LINGVEIL_LEAD_MS"] ?? "") ?? 4) / 1000
    private var speed: CGFloat = 0   // points per second, fastest visible block
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
    func adopt(_ blocks: [Block], _ token: MotionTracker.Token) -> Bool {
        guard running, let w = window else { return false }
        let rects = blocks.map { b in
            CGRect(x: b.item.rect.minX - area.minX, y: area.maxY - b.item.rect.maxY, width: b.item.rect.width, height: b.item.rect.height)
        }
        guard let catchUp = tracker.setReference(token, rects) else { return false }
        previous = []; previousTime = 0
        if let m = catchUp, let sh = m.shifts {
            // Read from an older frame: put the blocks where their text is now before they appear.
            exact = sh.map { -CGFloat($0) }; hidden = m.hidden
            w.view.show(blocks, shifts: exact, hidden: hidden)
        } else {
            exact = []; hidden = []
            w.view.blocks = blocks
            dirty = false
        }
        return true
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
        guard let motion = tracker.frame(pb, time: shown) else { return }
        Task { @MainActor in self.changed(motion) }
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
        guard let s = m.shifts, let view = window?.view else { return }
        // Image rows grow downward; the view's y grows upward.
        let now = s.map { -CGFloat($0) }
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

    /// Reads and translates whatever changed: soon after the screen goes still, and every
    /// quarter second while it keeps moving at a readable pace (so text scrolled into view doesn't wait for the
    /// scrolling to stop).
    private func refreshLoop() async {
        while running, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(30))
            let still = Date().timeIntervalSince(lastChange) > 0.12
            guard dirty else { continue }
            if still {
                // Once things stop, read right away, even if a read from mid-scroll is still
                // under way (its result will be older and is dropped).
                guard !stillReading else { continue }
            } else {
                // While moving, only slow scrolling is worth reading: after a flick the frame
                // is out of date long before its text is.
                guard reading == 0, Date().timeIntervalSince(lastRefresh) > 0.25, speed < 1500 else { continue }
            }
            dirty = false
            lastRefresh = Date()
            guard let token = tracker.begin(), let pixels = token.pixels else { Debug.log("follow: no frame to read"); continue }
            reading += 1
            if still { stillReading = true }
            onBusy?(true)
            Task {
                defer {
                    reading -= 1
                    if still { stillReading = false }
                    onBusy?(reading > 0)
                }
                let t0 = Date()
                let snap = Snapshot(pixels: pixels, frame: area, scale: CGFloat(tracker.scale))
                let app = self.app()
                // Accessibility reports where text is now, which only matches the frame if the
                // screen is still.
                let items = await Pipeline.items(in: snap, app: app, fastOCR: !still, accessibility: still)
                let blocks: [Block]
                do { blocks = try await Pipeline.blocks(for: items, in: snap, to: Language.named(Prefs.target), focus: Pipeline.frontWindowFrame(of: app)) } catch {
                    Debug.log("follow refresh failed: \(error.localizedDescription) (\(items.count) items)")
                    return
                }
                guard running, token.sequence > shownSequence else { return }
                Debug.log(String(format: "follow refresh %d blocks in %.0f ms (%@)", blocks.count, Date().timeIntervalSince(t0) * 1000, still ? "still" : "moving"))
                if adopt(blocks, token) { shownSequence = token.sequence } else { dirty = true }
            }
        }
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
        fileprivate let changes: Int; fileprivate let luma: [UInt8]; fileprivate let w: Int; fileprivate let h: Int; let pixels: PixelBuffer? }
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
            return Token(changes: changes, luma: luma, w: w, h: h, pixels: px)
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
