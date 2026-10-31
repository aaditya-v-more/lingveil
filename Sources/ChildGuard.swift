import Foundation

/// `Lingveil --child-guard <tool> <args…>` runs a helper tool and ends it as soon as this
/// app goes away. The app holds the guard's stdin open; when the app quits or crashes the
/// pipe closes, the guard sees end-of-file and stops the tool. macOS has no "kill me with my
/// parent" switch, and a model server left running would hold gigabytes of memory.
enum ChildGuard {
    static func run(_ args: [String]) -> Never {
        guard let tool = args.first else { exit(2) }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: tool)
        child.arguments = Array(args.dropFirst())
        child.standardInput = FileHandle.nullDevice
        child.terminationHandler = { exit($0.terminationStatus) }
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { child.terminate(); exit(0) }
            src.resume()
            sources.append(src)
        }
        do { try child.run() } catch { exit(1) }
        DispatchQueue.global().async {
            var b = [UInt8](repeating: 0, count: 64)
            while read(0, &b, 64) > 0 {}
            child.terminate()
            exit(0)
        }
        dispatchMain()
    }
    nonisolated(unsafe) private static var sources: [DispatchSourceSignal] = []
}
