import AppKit
import ScreenCaptureKit

/// Measures how closely followed translations stay on their text while scrolling, without
/// touching the screen anyone is using. `harness|<log>` (debug listener) starts a second
/// copy of Lingveil as `--scroll-harness <text> <log>`: a window behind all others that
/// scrolls itself on a script and logs where every line of text is. This copy follows that
/// window (captured directly, so being covered doesn't matter) with an invisible overlay and
/// logs where it shows each block. bench/follow.py compares the two.
@MainActor
enum Harness {
    private static var follower: Follower?
    private static var overlay: OverlayWindow?

    static func start(log: String) {
        let text = (log as NSString).deletingLastPathComponent + "/harness-text.txt"
        let child = Process()
        child.executableURL = URL(fileURLWithPath: Bundle.main.executablePath!)
        child.arguments = ["--scroll-harness", text, log + ".truth"]
        try? child.run()
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard let c = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
                  let w = c.windows.first(where: { $0.owningApplication?.processID == child.processIdentifier && $0.title == "Lingveil scroll test" }),
                  let screen = NSScreen.screens.first else { Debug.log("harness: window not found"); return }
            Debug.log("harness window \(w.windowID) onScreen=\(w.isOnScreen) active=\(w.isActive) frame=\(w.frame)")
            let top: CGFloat = 28
            let frame = Coords.fromQuartz(w.frame)
            let area = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height - top)
            let o = OverlayWindow(frame: area, interactive: false)
            o.alphaValue = 0   // nobody needs to see it; layers still move as usual
            o.orderFrontRegardless()
            let f = Follower(window: o, screen: screen, area: area)
            f.testWindow = (w, top)
            f.app = { nil }
            let out = FileHandle(forWritingAtPath: log) ?? { FileManager.default.createFile(atPath: log, contents: nil); return FileHandle(forWritingAtPath: log)! }()
            o.view.onMove = { [weak o] in
                guard let o else { return }
                let t = Date().timeIntervalSince1970
                let rows = o.view.debugPositions.map { String(format: "%.1f\t%.1f\t", $0.1, $0.2) + $0.0.replacingOccurrences(of: "\n", with: " ").prefix(40) }
                out.write(Data((String(format: "shown %.4f %d\n", t, rows.count) + rows.map { "  " + $0 + "\n" }.joined()).utf8))
            }
            follower = f; overlay = o
            await f.start()
            child.terminationHandler = { _ in Task { @MainActor in f.stop(); o.orderOut(nil); Debug.log("harness done") } }
        }
    }

    /// The scrolling window (runs in its own process).
    static func runWindow(text: String, log: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let content = (try? String(contentsOfFile: text, encoding: .utf8)) ?? String(repeating: "Lorem ipsum dolor sit amet.\n", count: 400)
        let w = NSWindow(contentRect: CGRect(x: 160, y: 140, width: 760, height: 620), styleMask: [.titled], backing: .buffered, defer: false)
        w.title = "Lingveil scroll test"
        let sv = NSTextView.scrollableTextView()
        let tv = sv.documentView as! NSTextView
        tv.string = content
        tv.font = .systemFont(ofSize: 14)
        tv.textContainerInset = .zero
        w.contentView = sv
        w.orderBack(nil)
        FileManager.default.createFile(atPath: log, contents: nil)
        let out = FileHandle(forWritingAtPath: log)!
        // Where every line is, in document points from the top.
        tv.layoutManager!.ensureLayout(for: tv.textContainer!)
        tv.layoutManager!.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: tv.layoutManager!.numberOfGlyphs)) { r, _, _, g, _ in
            let chars = tv.layoutManager!.characterRange(forGlyphRange: g, actualGlyphRange: nil)
            let line = (content as NSString).substring(with: chars).trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { out.write(Data(String(format: "line %.1f\t%@\n", r.minY, line).utf8)) }
        }
        // Script: settle, slow scroll, pause, flick, pause, scroll back, pause.
        let steps: [(duration: Double, by: CGFloat, ease: Bool)] = [(5, 0, false), (1.2, 700, true), (2.5, 0, false), (0.5, 1400, false), (2.5, 0, false), (1.0, -900, true), (2.5, 0, false)]
        var y: CGFloat = 0
        let t0 = Date()
        var stepStart = t0, stepIndex = 0, from: CGFloat = 0
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in
            let now = Date()
            let s = steps[stepIndex]
            var p = min(1, now.timeIntervalSince(stepStart) / s.duration)
            p = s.ease ? p * p * (3 - 2 * p) : 1 - pow(1 - p, 3)   // flicks decelerate
            y = from + s.by * CGFloat(p)
            sv.contentView.scroll(to: CGPoint(x: 0, y: y))
            sv.reflectScrolledClipView(sv.contentView)
            out.write(Data(String(format: "offset %.4f %.1f\n", now.timeIntervalSince1970, sv.contentView.bounds.minY).utf8))
            if now.timeIntervalSince(stepStart) >= s.duration {
                stepIndex += 1; stepStart = now; from = y
                if stepIndex == steps.count { exit(0) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        app.run()
        exit(0)
    }
}
