import AppKit
import ScreenCaptureKit

/// A captured piece of the screen. `frame` is in global AppKit points (origin bottom-left
/// of the primary display); the pixels cover exactly that rect at `scale` pixels per point.
struct Snapshot {
    let pixels: PixelBuffer
    let frame: CGRect
    let scale: CGFloat

    init(pixels: PixelBuffer, frame: CGRect, scale: CGFloat) {
        self.pixels = pixels; self.frame = frame; self.scale = scale
    }

    init?(image: CGImage, frame: CGRect, scale: CGFloat) {
        guard let p = PixelBuffer(image) else { return nil }
        self.init(pixels: p, frame: frame, scale: scale)
    }

    var image: CGImage { pixels.cgImage }

    /// Global AppKit rect -> pixel rect (top-left origin).
    func pixelRect(_ r: CGRect) -> CGRect {
        CGRect(x: (r.minX - frame.minX) * scale, y: (frame.maxY - r.maxY) * scale,
               width: r.width * scale, height: r.height * scale)
    }
}

/// sRGB BGRA pixels in memory mapped directly from the kernel. A screen is ~30 MB, and
/// mapping it ourselves means it is returned the moment the translation is done, instead
/// of lingering in malloc's caches or in a decoded-image cache.
final class PixelBuffer: @unchecked Sendable {
    let width: Int, height: Int
    let base: UnsafeMutableRawPointer
    var bytesPerRow: Int { width * 4 }
    var count: Int { width * height * 4 }
    static let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    static let space = CGColorSpace(name: CGColorSpace.sRGB)!

    init?(width: Int, height: Int) {
        guard width > 0, height > 0 else { return nil }
        let m = mmap(nil, width * height * 4, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)
        guard let m, m != MAP_FAILED else { return nil }
        self.width = width; self.height = height; base = m
    }

    convenience init?(_ image: CGImage) {
        self.init(width: image.width, height: image.height)
        guard let ctx = CGContext(data: base, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: Self.space, bitmapInfo: Self.bitmapInfo) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    deinit { munmap(base, count) }

    /// A CGImage over these bytes (no copy); keeps the buffer alive while it exists.
    var cgImage: CGImage {
        let provider = CGDataProvider(dataInfo: Unmanaged.passRetained(self).toOpaque(), data: base, size: count) { info, _, _ in
            Unmanaged<PixelBuffer>.fromOpaque(info!).release()
        }!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: Self.space, bitmapInfo: CGBitmapInfo(rawValue: Self.bitmapInfo), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// (r, g, b) in 0...1 at a pixel, top-left origin.
    @inline(__always) func rgb(_ x: Int, _ y: Int) -> RGB {
        let p = base.assumingMemoryBound(to: UInt8.self) + (y * width + x) * 4
        return RGB(Double(p[2]) / 255, Double(p[1]) / 255, Double(p[0]) / 255)
    }
}

enum Capture {
    private static var cached: (SCShareableContent, Date)?

    /// Shareable content is slow to query (~50-100 ms), so it is reused for a few seconds.
    static func content(fresh: Bool = false) async throws -> SCShareableContent {
        if !fresh, let (c, t) = cached, Date().timeIntervalSince(t) < 5 { return c }
        let c = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        cached = (c, Date())
        return c
    }

    static func display(for screen: NSScreen, in c: SCShareableContent) -> SCDisplay? {
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        return c.displays.first { $0.displayID == id }
    }

    /// Everything on `screen` except this app's own windows (overlays, bubbles, settings).
    /// Our app only appears in the shareable list while it has a window on screen; when it
    /// is missing from a cached list, the list is fetched again so it can be excluded.
    static func filter(for screen: NSScreen) async throws -> (SCContentFilter, SCDisplay) {
        let pid = ProcessInfo.processInfo.processIdentifier
        var c = try await content()
        if !c.applications.contains(where: { $0.processID == pid }) { c = try await content(fresh: true) }
        guard let d = display(for: screen, in: c) else { throw LingveilError.message("Display not found") }
        let me = c.applications.filter { $0.processID == pid }
        return (SCContentFilter(display: d, excludingApplications: me, exceptingWindows: []), d)
    }

    /// Captures `rect` (global AppKit points) on `screen`, or the whole screen.
    static func snapshot(_ screen: NSScreen, rect: CGRect? = nil) async throws -> Snapshot {
        let (filter, _) = try await filter(for: screen)
        let area = (rect ?? screen.frame).intersection(screen.frame)
        let scale = screen.backingScaleFactor
        let cfg = SCStreamConfiguration()
        cfg.sourceRect = localRect(area, on: screen)
        cfg.width = Int(area.width * scale)
        cfg.height = Int(area.height * scale)
        cfg.showsCursor = false
        cfg.captureResolution = .best
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        guard let snap = Snapshot(image: image, frame: area, scale: scale) else { throw LingveilError.message("Could not read the screen") }
        return snap
    }

    /// Global AppKit rect -> display-local rect with top-left origin, as ScreenCaptureKit wants.
    static func localRect(_ r: CGRect, on screen: NSScreen) -> CGRect {
        CGRect(x: r.minX - screen.frame.minX, y: screen.frame.maxY - r.maxY, width: r.width, height: r.height)
    }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }
}

enum LingveilError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

extension NSScreen {
    static var underMouse: NSScreen {
        let p = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(p, $0.frame, false) } ?? main ?? screens[0]
    }
}

/// Converts between AppKit global coordinates (bottom-left origin) and the
/// top-left-origin global coordinates used by Accessibility and Quartz.
enum Coords {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }
    static func fromQuartz(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }
    static func toQuartz(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: primaryHeight - p.y) }
}
