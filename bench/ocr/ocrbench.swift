// Times the text recognizers macOS offers on rendered text whose content is known, and
// scores them by character error rate. usage: ocrbench <text file> [width] [height]
import AppKit
import Vision
import VisionKit

let args = CommandLine.arguments
let text = (try? String(contentsOfFile: args[1], encoding: .utf8)) ?? ""
let W = CGFloat(Double(args.count > 2 ? args[2] : "760")!), H = CGFloat(Double(args.count > 3 ? args[3] : "590")!)

// Render the first screenful at 2x, like a Retina window, and keep the visible lines.
let tv = NSTextView(frame: CGRect(x: 0, y: 0, width: W, height: 100000))
let fontSize = CGFloat(Double(args.count > 4 ? args[4] : "14")!)
tv.string = text; tv.font = .systemFont(ofSize: fontSize); tv.textContainerInset = .zero
tv.layoutManager!.ensureLayout(for: tv.textContainer!)
var truth: [String] = []
tv.layoutManager!.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: tv.layoutManager!.numberOfGlyphs)) { r, _, _, g, _ in
    guard r.maxY <= H else { return }
    let c = tv.layoutManager!.characterRange(forGlyphRange: g, actualGlyphRange: nil)
    let l = (text as NSString).substring(with: c).trimmingCharacters(in: .whitespacesAndNewlines)
    if !l.isEmpty { truth.append(l) }
}
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * 2), pixelsHigh: Int(H * 2), bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = CGSize(width: W, height: H)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor.textBackgroundColor.setFill(); CGRect(x: 0, y: 0, width: W, height: H).fill()
tv.frame = CGRect(x: 0, y: 0, width: W, height: H)


tv.displayIgnoringOpacity(tv.bounds, in: NSGraphicsContext.current!)
NSGraphicsContext.restoreGraphicsState()
let image = rep.cgImage!
try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/claude-501/ocrbench.png"))

func norm(_ s: String) -> [Character] { Array(s.lowercased().filter { !$0.isWhitespace }) }
func cer(_ got: String) -> Double {
    let a = norm(truth.joined(separator: " ")), b = norm(got)
    var prev = Array(0...b.count), cur = [Int](repeating: 0, count: b.count + 1)
    for i in 1...max(1, a.count) where !a.isEmpty {
        cur[0] = i
        for j in 1...max(1, b.count) where !b.isEmpty { cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)) }
        swap(&prev, &cur)
    }
    return Double(prev[b.count]) / Double(max(1, a.count))
}
func ordered(_ r: [(String, CGRect)]) -> String { r.sorted { abs($0.1.midY - $1.1.midY) > 0.004 ? $0.1.midY > $1.1.midY : $0.1.minX < $1.1.minX }.map(\.0).joined(separator: " ") }

func vision(_ fast: Bool, langs: [String]?, correct: Bool, roi: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> [(String, CGRect)] {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = fast ? .fast : .accurate
    req.usesLanguageCorrection = correct
    if let langs { req.recognitionLanguages = langs; req.automaticallyDetectsLanguage = false } else { req.automaticallyDetectsLanguage = true }
    req.regionOfInterest = roi
    try? VNImageRequestHandler(cgImage: image, options: [:]).perform([req])
    return (req.results ?? []).compactMap { o in o.topCandidates(1).first.map { ($0.string, o.boundingBox) } }
}

@available(macOS 15.0, *)
func swiftVision(_ fast: Bool, langs: [Locale.Language]?) async -> [(String, CGRect)] {
    var req = RecognizeTextRequest()
    req.recognitionLevel = fast ? .fast : .accurate
    if let langs { req.recognitionLanguages = langs; req.automaticallyDetectsLanguage = false }
    let obs = (try? await req.perform(on: image)) ?? []
    return obs.compactMap { o in o.topCandidates(1).first.map { ($0.string, o.boundingBox.cgRect) } }
}

@MainActor
func liveText() async -> String {
    let analyzer = ImageAnalyzer()
    let conf = ImageAnalyzer.Configuration([.text])
    let a = try? await analyzer.analyze(image, orientation: .up, configuration: conf)
    return a?.transcript ?? ""
}

func time(_ name: String, _ runs: Int = 3, _ f: () async -> String) async {
    _ = await f()   // warm up (model load)
    var best = Double.infinity, out = ""
    for _ in 0..<runs { let t = Date(); out = await f(); best = min(best, Date().timeIntervalSince(t)) }
    print(String(format: "%-46@ %6.0f ms  CER %5.1f%%", name as NSString, best * 1000, cer(out) * 100))
}

setvbuf(stdout, nil, _IOLBF, 0)
print("\(truth.count) lines, \(Int(W))x\(Int(H)) pt at 2x")
await time("Vision accurate, auto language (current)") { ordered(vision(false, langs: nil, correct: true)) }
await time("Vision accurate, en-US, correction") { ordered(vision(false, langs: ["en-US"], correct: true)) }
await time("Vision accurate, en-US, no correction") { ordered(vision(false, langs: ["en-US"], correct: false)) }
await time("Vision fast, auto (current while moving)") { ordered(vision(true, langs: nil, correct: false)) }
await time("Vision fast, en-US") { ordered(vision(true, langs: ["en-US"], correct: false)) }
await time("Vision accurate, en-US, 15% strip") { ordered(vision(false, langs: ["en-US"], correct: true, roi: CGRect(x: 0, y: 0.85, width: 1, height: 0.15))) }
if #available(macOS 15.0, *) {
    await time("RecognizeTextRequest accurate, auto") { ordered(await swiftVision(false, langs: nil)) }
    await time("RecognizeTextRequest accurate, en") { ordered(await swiftVision(false, langs: [Locale.Language(identifier: "en-US")])) }
}
await time("VisionKit ImageAnalyzer (Live Text)") { await liveText() }

// Same accurate reading, in horizontal tiles read at the same time (tiles overlap by 40 px
// so a line on a boundary is whole in one of them).
func tiled(_ n: Int) -> [(String, CGRect)] {
    var out = [[(String, CGRect)]](repeating: [], count: n)
    let overlap = 40.0 / Double(image.height)
    DispatchQueue.concurrentPerform(iterations: n) { k in
        let y0 = max(0, Double(k) / Double(n) - overlap), y1 = min(1, Double(k + 1) / Double(n) + overlap)
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate; req.usesLanguageCorrection = true; req.automaticallyDetectsLanguage = true
        req.regionOfInterest = CGRect(x: 0, y: y0, width: 1, height: y1 - y0)
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([req])
        // ROI boxes are relative to the region; keep lines whose centre is in this tile's own band.
        out[k] = (req.results ?? []).compactMap { o in
            let cy = y0 + o.boundingBox.midY * (y1 - y0)
            guard cy >= Double(k) / Double(n), cy < Double(k + 1) / Double(n) else { return nil }
            return o.topCandidates(1).first.map { ($0.string, CGRect(x: o.boundingBox.minX, y: cy, width: o.boundingBox.width, height: 0)) }
        }
    }
    return out.flatMap { $0 }
}
for n in [2, 4, 6] { await time("Vision accurate, \(n) tiles in parallel") { ordered(tiled(n)) } }
