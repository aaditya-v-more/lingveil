import AppKit
import ScreenCaptureKit

/// `LINGVEIL_DEBUG_IMAGE=<png> LINGVEIL_DEBUG_OUT=<png>` runs the whole pipeline on an image
/// (as if it were a 2x screen), writes the image with the translation painted on top,
/// prints timings and the blocks, and exits. Used to check quality without a display.
@MainActor
enum Debug {
    static func runIfRequested() -> Bool {
        let env = ProcessInfo.processInfo.environment
        if let file = env["LINGVEIL_DEBUG_TEXTS"] {
            let texts = ((try? String(contentsOfFile: file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
            Task {
                for round in 0..<2 {
                    let t = Date()
                    _ = try? await GoogleWeb().translate(texts.map { $0 + (round == 0 ? "" : " ") }, to: Language.named(env["LINGVEIL_TARGET"] ?? "hi"))
                    print(String(format: "round %d: %d texts in %.0f ms", round, texts.count, Date().timeIntervalSince(t) * 1000))
                }
                exit(0)
            }
            return true
        }
        guard let input = env["LINGVEIL_DEBUG_IMAGE"], let out = env["LINGVEIL_DEBUG_OUT"] else { return false }
        Task {
            guard let src = NSImage(contentsOfFile: input)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                print("cannot read \(input)"); exit(1)
            }
            let scale: CGFloat = CGFloat(Double(env["LINGVEIL_SCALE"] ?? "2") ?? 2)
            let frame = CGRect(x: 0, y: 0, width: CGFloat(src.width) / scale, height: CGFloat(src.height) / scale)
            guard let snap = Snapshot(image: src, frame: frame, scale: scale) else { exit(1) }
            let t0 = Date()
            let items = await Pipeline.items(in: snap, app: nil)
            let t1 = Date()
            do {
                let blocks = try await Pipeline.blocks(for: items, in: snap, to: Language.named(Prefs.target))
                let t2 = Date()
                print(String(format: "items %d  blocks %d  ocr %.0f ms  translate+colors %.0f ms", items.count, blocks.count,
                             t1.timeIntervalSince(t0) * 1000, t2.timeIntervalSince(t1) * 1000))
                for b in blocks { print("•", b.item.lines, Int(b.item.rect.minX), Int(b.item.rect.minY), Int(b.item.rect.width), Int(b.item.rect.height), b.item.text.prefix(40), "→", b.translation.prefix(40)) }
                write(snap, blocks, to: out)
            } catch { print("error:", error.localizedDescription) }
            exit(0)
        }
        return true
    }

    /// `LINGVEIL_DEBUG_DIR=<dir>`: the posted distributed notification `com.aadityavmore.lingveil.debug`
    /// (object = action name, e.g. "screen") runs that action for real, then saves the screen
    /// with the overlay on it to <dir>/<action>.png and the timings/blocks to <dir>/<action>.txt.
    static func listenIfRequested() {
        guard let dir = ProcessInfo.processInfo.environment["LINGVEIL_DEBUG_DIR"] else { return }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.aadityavmore.lingveil.debug"), object: nil, queue: .main) { n in
            let name = n.object as? String ?? "screen"
            if name == "relieve" { malloc_zone_pressure_relief(nil, 0); return }
            guard let a = Action(rawValue: name) else { return }
            MainActor.assumeIsolated {
                let t0 = Date()
                (NSApp.delegate as? AppDelegate)?.perform(a)
                Task {
                    var log = ""
                    Pipeline.timings = ""
                    for _ in 0..<80 {
                        try? await Task.sleep(for: .milliseconds(50))
                        if let v = OneShot.shared.debugView, !v.blocks.isEmpty || v.status?.hasPrefix("Nothing") == true { break }
                    }
                    log += String(format: "ready after %.0f ms\n", Date().timeIntervalSince(t0) * 1000) + Pipeline.timings + "\n"
                    for b in OneShot.shared.debugView?.blocks ?? [] {
                        log += "\(b.item.fromAX ? "AX " : "OCR") \(Int(b.item.rect.minX)),\(Int(b.item.rect.minY)) \(b.item.font?.fontName ?? "-") \(b.item.text.prefix(40)) -> \(b.translation.prefix(50))\n"
                    }
                    for _ in 0..<60 where !Pipeline.timings.contains("translate") { try? await Task.sleep(for: .milliseconds(50)) }
                    log += String(format: "all done after %.0f ms: ", Date().timeIntervalSince(t0) * 1000) + Pipeline.timings + "\n"
                    try? await Task.sleep(for: .milliseconds(200))
                    let screen = NSScreen.underMouse
                    if let c = try? await Capture.content(), let d = Capture.display(for: screen, in: c) {
                        let cfg = SCStreamConfiguration()
                        cfg.width = Int(screen.frame.width * screen.backingScaleFactor); cfg.height = Int(screen.frame.height * screen.backingScaleFactor)
                        if let img = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: d, excludingWindows: []), configuration: cfg) {
                            let rep = NSBitmapImageRep(cgImage: img)
                            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/\(name).png"))
                        }
                    }
                    try? log.write(toFile: dir + "/\(name).txt", atomically: true, encoding: .utf8)
                }
            }
        }
    }

    private static func write(_ snap: Snapshot, _ blocks: [Block], to path: String) {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: snap.image.width, pixelsHigh: snap.image.height,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = snap.frame.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSImage(cgImage: snap.image, size: snap.frame.size).draw(in: CGRect(origin: .zero, size: snap.frame.size))
        let v = OverlayView(frame: CGRect(origin: .zero, size: snap.frame.size))
        v.blocks = blocks
        v.draw(v.bounds)
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
