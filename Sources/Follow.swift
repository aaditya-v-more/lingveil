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
    private let queue = DispatchQueue(label: "lingveil.follow", qos: .userInitiated)
    nonisolated let tracker = MotionTracker()
    private var lastChange = Date.distantPast
    private var lastRefresh = Date()
    private var working = false
    private(set) var running = false
    var onBusy: ((Bool) -> Void)?

    init(window: OverlayWindow, screen: NSScreen, area: CGRect) {
        self.window = window; self.screen = screen; self.area = area
    }

    /// Starts watching and returns once the first frame is in.
    func start() async {
        do {
            let (filter, _) = try await Capture.filter(for: screen)
            let cfg = SCStreamConfiguration()
            cfg.sourceRect = Capture.localRect(area, on: screen)
            cfg.width = Int(area.width); cfg.height = Int(area.height)
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            cfg.queueDepth = 3
            cfg.showsCursor = false
            cfg.pixelFormat = kCVPixelFormatType_32BGRA
            let s = SCStream(filter: filter, configuration: cfg, delegate: self)
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await s.startCapture()
            stream = s
            running = true
            for _ in 0..<40 where !tracker.hasFrame { try? await Task.sleep(for: .milliseconds(25)) }
        } catch { Debug.log("follow could not start: \(error.localizedDescription)") }
    }

    func stop() {
        running = false
        let s = stream; stream = nil
        Task { try? await s?.stopCapture() }
        tracker.reset()
    }

    /// Shows `blocks` (read from a capture taken when `token` was) if the screen hasn't
    /// changed since; otherwise the caller shows them anyway and they are read again.
    @discardableResult
    func adopt(_ blocks: [Block], _ token: MotionTracker.Token) -> Bool {
        guard running, let w = window else { return false }
        let rects = blocks.map { b in
            CGRect(x: b.item.rect.minX - area.minX, y: area.maxY - b.item.rect.maxY, width: b.item.rect.width, height: b.item.rect.height)
        }
        guard tracker.setReference(token, rects) else { return false }
        w.view.blocks = blocks
        return true
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = sb.imageBuffer else { return }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        guard let motion = tracker.frame(base, CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb), CVPixelBufferGetBytesPerRow(pb)) else { return }
        Task { @MainActor in self.changed(motion) }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Debug.log("follow stream stopped: \(error.localizedDescription)")
    }

    private func changed(_ m: MotionTracker.Motion) {
        guard running else { return }
        lastChange = Date()
        if let sh = m.shifts { Debug.log("follow change \(Dictionary(grouping: sh, by: { $0 }).mapValues(\.count)) hidden=\(m.hidden.count)") }
        if let shifts = m.shifts, m.reference == tracker.referenceID {
            // Image rows grow downward; the view's y grows upward.
            window?.view.move(shifts.map { -CGFloat($0) }, hidden: m.hidden)
        }
        refreshWhenStill()
    }

    /// Reads and translates again once nothing has moved for a moment.
    func refreshWhenStill() {
        guard !working, running else { return }
        working = true
        Task {
            defer { working = false }
            while running {
                while running, Date().timeIntervalSince(lastChange) < 0.3 || Date().timeIntervalSince(lastRefresh) < 0.8 {
                    try? await Task.sleep(for: .milliseconds(60))
                }
                guard running else { return }
                lastRefresh = Date()
                Debug.log("follow refresh start")
                let token = tracker.begin()
                onBusy?(true)
                let t0 = Date()
                let blocks = try? await translate()
                onBusy?(false)
                guard running else { return }
                Debug.log(String(format: "follow refresh %d blocks in %.0f ms", blocks?.count ?? -1, Date().timeIntervalSince(t0) * 1000))
                if let blocks, adopt(blocks, token) { return }
            }
        }
    }

    private func translate() async throws -> [Block] {
        let app = Pipeline.frontApp
        let snap = try await Capture.snapshot(screen, rect: area)
        let items = await Pipeline.items(in: snap, app: app)
        return try await Pipeline.blocks(for: items, in: snap, to: Language.named(Prefs.target), focus: Pipeline.frontWindowFrame(of: app))
    }
}

/// Works out, from frame to frame, where each translated block's text has gone. Runs on
/// the capture queue; frames are kept as one byte of brightness per point.
final class MotionTracker: @unchecked Sendable {
    struct Token { fileprivate let changes: Int; fileprivate let luma: [UInt8]; fileprivate let w: Int; fileprivate let h: Int }
    struct Motion { let reference: Int; let shifts: [Int]?; let hidden: Set<Int> }

    private struct Box { let x0, x1, y0, y1: Int; let contrast: Float }

    private let lock = NSLock()
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

    func reset() { lock.withLock { luma = []; print = []; boxes = []; ref = []; refID += 1 } }

    /// What the screen looks like now, to compare with when a translation comes back.
    func begin() -> Token { lock.withLock { Token(changes: changes, luma: luma, w: w, h: h) } }

    /// Makes `rects` (top-down points within the area) the blocks to follow. Fails when the
    /// screen changed after `t` was taken, since the blocks would then be out of date.
    func setReference(_ t: Token, _ rects: [CGRect]) -> Bool {
        lock.withLock {
            guard t.changes == changes, !t.luma.isEmpty, t.w == w, t.h == h else { return false }
            ref = t.luma
            refSmall = Self.shrink(ref, w, h)
            boxes = rects.map { r in
                let x0 = max(0, Int(r.minX)), x1 = min(w, Int(r.maxX)), y0 = max(0, Int(r.minY)), y1 = min(h, Int(r.maxY))
                return Box(x0: x0, x1: max(x0, x1), y0: y0, y1: max(y0, y1), contrast: Self.contrast(ref, w, x0, max(x0, x1), y0, max(y0, y1)))
            }
            last = Array(repeating: 0, count: rects.count)
            lastBand = Array(repeating: 0, count: Self.bandCount)
            refID += 1
            return true
        }
    }

    /// nil when the frame looks the same as the previous one.
    func frame(_ base: UnsafeMutableRawPointer, _ fw: Int, _ fh: Int, _ row: Int) -> Motion? {
        let fp = Live.fingerprint(base, fw, fh, row)
        lock.lock(); defer { lock.unlock() }
        guard Live.differs(fp, print) else { return nil }
        print = fp
        var l = [UInt8](repeating: 0, count: fw * fh)
        let p = base.assumingMemoryBound(to: UInt8.self)
        l.withUnsafeMutableBufferPointer { out in
            for y in 0..<fh {
                let r = p + y * row, o = y * fw
                for x in 0..<fw { let q = r + x * 4; out[o + x] = UInt8((Int(q[0]) + 2 * Int(q[1]) + Int(q[2])) >> 2) }
            }
        }
        if fw != w || fh != h { w = fw; h = fh; boxes = []; ref = [] }
        luma = l
        changes += 1
        guard !boxes.isEmpty else { return Motion(reference: refID, shifts: nil, hidden: []) }

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
                let s = Self.sad(ref, l, w, h, b.x0, b.x1, b.y0, b.y1, d, step: 2, minRows: max(1, (b.y1 - b.y0) * 2 / 3)) / max(b.contrast, 4) * Self.near(d, last[i])
                if s < best.0 { best = (s, d) }
            }
            if best.0 < 0.35 { shifts[i] = best.1; last[i] = best.1 } else { hidden.insert(i); shifts[i] = last[i] }
        }
        return Motion(reference: refID, shifts: shifts, hidden: hidden)
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
