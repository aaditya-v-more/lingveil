import AppKit
import SwiftUI
import ScreenCaptureKit

/// `LINGVEIL_DEBUG_IMAGE=<png> LINGVEIL_DEBUG_OUT=<png>` runs the whole pipeline on an image
/// (as if it were a 2x screen), writes the image with the translation painted on top,
/// prints timings and the blocks, and exits. Used to check quality without a display.
@MainActor
enum Debug {
    static func runIfRequested() -> Bool {
        let env = ProcessInfo.processInfo.environment
        if let out = env["LINGVEIL_DEBUG_SETTINGS_PNG"] {
            // Renders a settings tab offscreen to a PNG (tab from LINGVEIL_DEBUG_TAB, default models).
            let model = SettingsModel()
            let tab = env["LINGVEIL_DEBUG_TAB"] ?? "models"
            if tab == "tutorial" {
                let host = NSHostingView(rootView: TutorialView {}.background(Color(nsColor: .windowBackgroundColor)))
                host.frame = CGRect(x: 0, y: 0, width: 560, height: 440)
                let w = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
                w.contentView = host
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                    }
                    exit(0)
                }
                return true
            }
            let t = SettingsWindow.Tab(rawValue: tab) ?? .models
            let size = SettingsWindow.order.first { $0.0 == t }?.3 ?? CGSize(width: 640, height: 600)
            let view = AnyView(SettingsView(m: model, only: t).frame(width: size.width, height: env["LINGVEIL_DEBUG_HEIGHT"] == nil ? size.height : nil))
            let height = Double(env["LINGVEIL_DEBUG_HEIGHT"] ?? "") ?? size.height
            let host = NSHostingView(rootView: view.frame(width: size.width, height: height))
            host.frame = CGRect(x: 0, y: 0, width: size.width, height: height)
            let w = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.contentView = host
            w.appearance = NSAppearance(named: env["LINGVEIL_DEBUG_DARK"] == nil ? .aqua : .darkAqua)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                }
                exit(0)
            }
            return true
        }
        if let file = env["LINGVEIL_DEBUG_TEXTS"] {
            let texts = ((try? String(contentsOfFile: file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
            Task {
                for round in 0..<2 {
                    let t = Date()
                    do {
                        let out = try await Translation.translate(texts.map { $0 + String(repeating: " ", count: round) }, to: Language.named(Prefs.target))
                        if round == 1, let path = env["LINGVEIL_DEBUG_TEXTS_OUT"] {
                            try? out.map { $0.replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
                        }
                    } catch { print("error:", error.localizedDescription) }
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
                for b in blocks { print("•", String(format: "stroke %.3f L%.0f R%.0f", b.around.stroke, b.around.left, b.around.right), b.item.lines, Int(b.item.rect.minX), Int(b.item.rect.minY), Int(b.item.rect.width), Int(b.item.rect.height), b.item.text.prefix(40), "→", b.translation.prefix(40)) }
                write(snap, blocks, to: out)
            } catch { print("error:", error.localizedDescription) }
            exit(0)
        }
        return true
    }

    /// Set by the debug listener so area and pointer modes can run without a person
    /// dragging or pointing: the next region pick / pointer lookup uses these instead.
    /// Appends a line to <LINGVEIL_DEBUG_DIR>/log.txt when debugging; otherwise does nothing.
    nonisolated static func log(_ s: @autoclosure () -> String) {
        guard let dir = ProcessInfo.processInfo.environment["LINGVEIL_DEBUG_DIR"] else { return }
        let line = String(format: "%.3f ", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000)) + s() + "\n"
        if let h = FileHandle(forWritingAtPath: dir + "/log.txt") { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? line.write(toFile: dir + "/log.txt", atomically: false, encoding: .utf8) }
    }

    static var rect: CGRect?
    static var point: CGPoint?

    /// `LINGVEIL_DEBUG_DIR=<dir>`: the distributed notification `com.aadityavmore.lingveil.debug`
    /// with object "<action>[|x,y,w,h]" runs that action for real (area/live use the rect,
    /// cursor uses its origin as the pointer), waits for the result, then saves the screen to
    /// <dir>/<action>.png and what it found to <dir>/<action>.txt. "stop" ends live mode.
    static func listenIfRequested() {
        guard let dir = ProcessInfo.processInfo.environment["LINGVEIL_DEBUG_DIR"] else { return }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.aadityavmore.lingveil.debug"), object: nil, queue: .main) { n in
            let parts = (n.object as? String ?? "screen").split(separator: "|").map(String.init)
            let name = parts[0]
            if name == "relieve" { malloc_zone_pressure_relief(nil, 0); return }
            MainActor.assumeIsolated {
                if name == "supportcard" { Support.debugShow(); return }
                if name == "shot" {
                    Task {
                        let screen = NSScreen.main ?? NSScreen.underMouse
                        if let c = try? await Capture.content(), let d = Capture.display(for: screen, in: c) {
                            let cfg = SCStreamConfiguration()
                            cfg.width = Int(screen.frame.width * screen.backingScaleFactor); cfg.height = Int(screen.frame.height * screen.backingScaleFactor)
                            if let img = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: d, excludingWindows: []), configuration: cfg) {
                                try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/shot.png"))
                            }
                        }
                    }
                    return
                }
                if name == "stop" { Live.shared.stop(); OneShot.shared.dismiss(); Bubble.shared.close(); return }
                if parts.count > 1 {
                    let v = parts[1].split(separator: ",").compactMap { Double($0) }
                    if v.count == 4 { rect = CGRect(x: v[0], y: v[1], width: v[2], height: v[3]); point = rect!.origin }
                }
                if name == "download", parts.count > 1, let m = LocalModel.named(parts[1]) {
                    // Runs the real downloader and logs progress every few seconds.
                    ModelStore.shared.delete(m)
                    ModelStore.shared.download(m)
                    let t0 = Date()
                    Task {
                        while true {
                            try? await Task.sleep(for: .seconds(5))
                            let st = ModelStore.shared
                            Debug.log(String(format: "download %@ %.0f s progress=%@ verifying=%@ installed=%@ error=%@", m.id, Date().timeIntervalSince(t0),
                                             st.progress[m.id].map { String(format: "%.2f", $0) } ?? "-", String(st.verifying.contains(m.id)),
                                             String(st.isInstalled(m)), st.errors[m.id] ?? "-"))
                            if st.isInstalled(m) || st.errors[m.id] != nil { break }
                        }
                    }
                    return
                }
                if name == "voicedownload", parts.count > 1, let m = VoiceCatalog.shared.models.first(where: { $0.id == parts[1] }) {
                    VoiceStore.shared.download(m)
                    let t0 = Date()
                    Task {
                        while true {
                            try? await Task.sleep(for: .seconds(2))
                            let st = VoiceStore.shared
                            Debug.log(String(format: "voice %@ %.0f s progress=%@ installed=%@ error=%@", m.id, Date().timeIntervalSince(t0),
                                             st.progress[m.id].map { String(format: "%.2f", $0) } ?? "-", String(st.installed.contains(m.id)), st.errors[m.id] ?? "-"))
                            if st.progress[m.id] == nil { break }
                        }
                    }
                    return
                }
                if name == "say", parts.count > 2 {
                    // say|<language>|<text>: reads it with the chosen voice engine.
                    let t0 = Date()
                    Narrator.shared.read([Segment(text: parts[2], rect: nil, language: parts[1])]) { i in
                        Debug.log(String(format: "say highlight %@ at %.0f ms", i.map(String.init) ?? "end", Date().timeIntervalSince(t0) * 1000))
                    }
                    return
                }
                if name == "dump" {
                    let blocks = Live.shared.debugView?.blocks ?? []
                    let log = blocks.map { "\($0.item.text.prefix(40)) -> \($0.translation.prefix(60))" }.joined(separator: "\n")
                    try? log.write(toFile: dir + "/dump.txt", atomically: true, encoding: .utf8)
                    return
                }
                guard let a = Action(rawValue: name) else { return }
                let t0 = Date()
                Pipeline.timings = ""
                (NSApp.delegate as? AppDelegate)?.perform(a)
                Task {
                    @MainActor func done() -> Bool {
                        switch a {
                        case .screen, .area:
                            guard let v = OneShot.shared.debugView else { return false }
                            return !v.blocks.isEmpty || v.status?.hasPrefix("Nothing") == true
                        case .live: return !(Live.shared.debugView?.blocks.isEmpty ?? true)
                        case .cursor, .selection: return Bubble.shared.debugText != nil
                        case .read, .translateRead: return Narrator.shared.isSpeaking
                        }
                    }
                    for _ in 0..<120 where !done() { try? await Task.sleep(for: .milliseconds(50)) }
                    var log = String(format: "ready after %.0f ms\n", Date().timeIntervalSince(t0) * 1000)
                    for _ in 0..<600 where (a == .screen || a == .area) && !Pipeline.timings.contains("translate") { try? await Task.sleep(for: .milliseconds(50)) }
                    log += Pipeline.timings + "\n"
                    let blocks = (a == .live ? Live.shared.debugView : OneShot.shared.debugView)?.blocks ?? []
                    for b in blocks {
                        log += "\(b.item.fromAX ? "AX " : "OCR") \(Int(b.item.rect.minX)),\(Int(b.item.rect.minY)) \(b.item.font?.fontName ?? "-") \(b.item.text.prefix(40)) -> \(b.translation.prefix(50))\n"
                    }
                    if let t = Bubble.shared.debugText { log += "bubble: \(t)\n" }
                    try? await Task.sleep(for: .milliseconds(250))
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
        for (t, est, final, al) in v.debugSizes { print(String(format: "  size est %.1f final %.1f align %d  ", est ?? 0, final, al.rawValue) + t.prefix(30)) }
        v.draw(v.bounds)
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
