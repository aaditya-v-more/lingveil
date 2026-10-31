import AppKit
import Darwin

/// Text recognition runs in a child copy of this app (`--ocr-helper`). Vision's models take
/// ~120 MB once loaded and can't be unloaded, so keeping them in a helper that quits after
/// a short idle period lets the menu bar app sit at a few tens of MB between uses.
/// Wire format, both ways over stdin/stdout:
///   request:  UInt32 width, height, flags (bit 0 = fast), minHeight(px)  + width*height*4 BGRA bytes
///   response: UInt32 byte count + JSON [[text, x, y, w, h], ...]
actor OCRHelper {
    static let shared = OCRHelper()
    static let idleExit: Int32 = 90_000   // ms

    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?

    func recognize(_ pixels: PixelBuffer, fast: Bool, minHeight: CGFloat) async -> [(String, CGRect)] {
        let bytes = Data(bytesNoCopy: pixels.base, count: pixels.count, deallocator: .none)
        for _ in 0..<2 {
            if let r = try? exchange(bytes, pixels.width, pixels.height, fast: fast, minHeight: minHeight) { return r }
            stop()
        }
        // Helper unavailable: do it here rather than fail.
        return withExtendedLifetime(pixels) { OCR.recognize(pixels.cgImage, fast: fast, minHeight: minHeight) }
    }

    /// Starts the helper and runs one tiny recognition so the models are compiled and
    /// cached before the first real use (the very first compile takes several seconds).
    func warmUp() async {
        let size = NSSize(width: 320, height: 60)
        let img = NSImage(size: size, flipped: false) { r in
            NSColor.white.setFill(); r.fill()
            ("Hello こんにちは 你好" as NSString).draw(at: CGPoint(x: 10, y: 20), withAttributes: [.font: NSFont.systemFont(ofSize: 22)])
            return true
        }
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil), let px = PixelBuffer(cg) else { return }
        _ = await recognize(px, fast: false, minHeight: 4)
    }

    private func exchange(_ pixels: Data, _ w: Int, _ h: Int, fast: Bool, minHeight: CGFloat) throws -> [(String, CGRect)] {
        try start()
        guard let input, let output else { throw LingveilError.message("no helper") }
        var header = [UInt32(w), UInt32(h), fast ? 1 : 0, UInt32(minHeight)]
        try input.write(contentsOf: Data(bytes: &header, count: 16))
        try input.write(contentsOf: pixels)
        guard let lenData = try output.read(upToCount: 4), lenData.count == 4 else { throw LingveilError.message("helper closed") }
        let len = Int(lenData.withUnsafeBytes { $0.load(as: UInt32.self) })
        var body = Data()
        while body.count < len, let chunk = try output.read(upToCount: len - body.count), !chunk.isEmpty { body.append(chunk) }
        guard let rows = try JSONSerialization.jsonObject(with: body) as? [[Any]] else { return [] }
        return rows.compactMap { r in
            guard r.count == 5, let t = r[0] as? String, let x = r[1] as? Double, let y = r[2] as? Double,
                  let bw = r[3] as? Double, let bh = r[4] as? Double else { return nil }
            return (t, CGRect(x: x, y: y, width: bw, height: bh))
        }
    }

    private func start() throws {
        if let p = process, p.isRunning { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
        p.arguments = ["--ocr-helper"]
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        process = p
        input = inPipe.fileHandleForWriting
        output = outPipe.fileHandleForReading
    }

    private func stop() {
        process?.terminate()
        process = nil; input = nil; output = nil
    }

    // MARK: helper side

    /// Entry point of the helper process. Exits on EOF or after `idleExit` ms without work.
    static func serve() -> Never {
        signal(SIGPIPE, SIG_IGN)
        setpriority(PRIO_PROCESS, 0, -5)
        while true {
            var pfd = pollfd(fd: 0, events: Int16(POLLIN), revents: 0)
            if poll(&pfd, 1, idleExit) <= 0 { exit(0) }
            guard let header = readExactly(16) else { exit(0) }
            let v = header.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
            let w = Int(v[0]), h = Int(v[1]), fast = v[2] & 1 == 1, minHeight = CGFloat(v[3])
            guard w > 0, h > 0, w * h < 120_000_000, let pixels = readExactly(w * h * 4) else { exit(1) }
            var rows: [[Any]] = []
            autoreleasepool {
                if let provider = CGDataProvider(data: pixels as CFData),
                   let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                     provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) {
                    rows = OCR.recognize(img, fast: fast, minHeight: minHeight).map { [$0.0, $0.1.minX, $0.1.minY, $0.1.width, $0.1.height] }
                }
            }
            let body = (try? JSONSerialization.data(withJSONObject: rows)) ?? Data("[]".utf8)
            var len = UInt32(body.count)
            FileHandle.standardOutput.write(Data(bytes: &len, count: 4))
            FileHandle.standardOutput.write(body)
        }
    }

    private static func readExactly(_ n: Int) -> Data? {
        var d = Data(count: n)
        var got = 0
        let ok = d.withUnsafeMutableBytes { raw -> Bool in
            while got < n {
                let r = read(0, raw.baseAddress! + got, n - got)
                if r <= 0 { return false }
                got += r
            }
            return true
        }
        return ok ? d : nil
    }
}
