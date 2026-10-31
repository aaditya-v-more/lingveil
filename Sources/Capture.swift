import AppKit
import ScreenCaptureKit

/// A captured piece of the screen. `frame` is in global AppKit points (origin bottom-left
/// of the primary display); the image covers exactly that rect at `scale` pixels per point.
struct Snapshot {
    let image: CGImage
    let frame: CGRect
    let scale: CGFloat

    /// Global AppKit rect -> pixel rect in `image` (top-left origin).
    func pixelRect(_ r: CGRect) -> CGRect {
        CGRect(x: (r.minX - frame.minX) * scale, y: (frame.maxY - r.maxY) * scale,
               width: r.width * scale, height: r.height * scale)
    }
}

enum Capture {
    private static var cached: (SCShareableContent, Date)?

    /// Shareable content is slow to query (~50-100 ms), so it is reused for a few seconds.
    static func content() async throws -> SCShareableContent {
        if let (c, t) = cached, Date().timeIntervalSince(t) < 5 { return c }
        let c = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        cached = (c, Date())
        return c
    }

    static func display(for screen: NSScreen, in c: SCShareableContent) -> SCDisplay? {
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        return c.displays.first { $0.displayID == id }
    }

    /// Everything on `screen` except this app's own windows (overlays, bubbles, settings).
    static func filter(for screen: NSScreen) async throws -> (SCContentFilter, SCDisplay) {
        let c = try await content()
        guard let d = display(for: screen, in: c) else { throw LingveilError.message("Display not found") }
        let me = c.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
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
        return Snapshot(image: image, frame: area, scale: scale)
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
