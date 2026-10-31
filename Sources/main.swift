import AppKit

if CommandLine.arguments.contains("--ocr-helper") { OCRHelper.serve() }
if let i = CommandLine.arguments.firstIndex(of: "--child-guard") { ChildGuard.run(Array(CommandLine.arguments[(i + 1)...])) }
if let i = CommandLine.arguments.firstIndex(of: "--scroll-harness"), CommandLine.arguments.count > i + 2 {
    MainActor.assumeIsolated { Harness.runWindow(text: CommandLine.arguments[i + 1], log: CommandLine.arguments[i + 2]) }
}
LlamaServer.cleanUpStale()
signal(SIGPIPE, SIG_IGN)

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
