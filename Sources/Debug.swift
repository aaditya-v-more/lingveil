import AppKit

/// `LINGVEIL_DEBUG_IMAGE=<png> LINGVEIL_DEBUG_OUT=<png>` runs the whole pipeline on an image
/// (as if it were a 2x screen), writes the image with the translation painted on top,
/// prints timings and the blocks, and exits. Used to check quality without a display.
@MainActor
enum Debug {
    static func runIfRequested() -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard let input = env["LINGVEIL_DEBUG_IMAGE"], let out = env["LINGVEIL_DEBUG_OUT"] else { return false }
        if let t = env["LINGVEIL_TARGET"] { Prefs.target = t }
        if let e = env["LINGVEIL_ENGINE"], let k = EngineKind(rawValue: e) { Prefs.engine = k }
        Task {
            guard let src = NSImage(contentsOfFile: input)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                print("cannot read \(input)"); exit(1)
            }
            let scale: CGFloat = CGFloat(Double(env["LINGVEIL_SCALE"] ?? "2") ?? 2)
            let frame = CGRect(x: 0, y: 0, width: CGFloat(src.width) / scale, height: CGFloat(src.height) / scale)
            let snap = Snapshot(image: src, frame: frame, scale: scale)
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
