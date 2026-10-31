import SwiftUI
import Carbon.HIToolbox

@MainActor
enum SettingsWindow {
    enum Tab: String { case general, shortcuts, models, voices, engines, permissions }
    private static var window: NSWindow?
    private static var tabs: NSTabViewController?
    private static let model = SettingsModel()
    /// One size for every tab: switching tabs never resizes the window.
    static let size = CGSize(width: 660, height: 620)
    static let order: [(Tab, String, String, CGSize)] = [
        (.general, "General", "gearshape", SettingsWindow.size),
        (.shortcuts, "Shortcuts", "command", SettingsWindow.size),
        (.models, "Models", "cpu", SettingsWindow.size),
        (.voices, "Voices", "speaker.wave.2", SettingsWindow.size),
        (.engines, "Online", "globe", SettingsWindow.size),
        (.permissions, "Permissions", "lock.shield", SettingsWindow.size),
    ]

    /// A standard macOS settings window: toolbar tabs, each sized to its content, and the
    /// window titled after the selected tab.
    static func show(tab: Tab = .general) {
        model.refresh()
        if window == nil {
            let vc = NSTabViewController()
            vc.tabStyle = .toolbar
            vc.transitionOptions = [.allowUserInteraction]
            for (t, title, icon, size) in order {
                let host = NSHostingController(rootView: SettingsView(m: model, only: t).frame(width: size.width, height: size.height, alignment: .top))
                host.preferredContentSize = size
                let item = NSTabViewItem(viewController: host)
                item.label = title
                item.image = NSImage(systemSymbolName: icon, accessibilityDescription: title)
                vc.addTabViewItem(item)
            }
            let w = NSWindow(contentViewController: vc)
            w.styleMask = [.titled, .closable]
            w.toolbarStyle = .preference
            w.addTitlebarAccessoryViewController(Support.titlebarButton())
            w.isReleasedWhenClosed = false
            w.center()
            window = w
            tabs = vc
        }
        if let i = order.firstIndex(where: { $0.0 == tab }) { tabs?.selectedTabViewItemIndex = i }
        model.tab = tab
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class SettingsModel: ObservableObject {
    @Published var tab: SettingsWindow.Tab = .general
    @Published var target = Prefs.target { didSet { Prefs.target = target } }
    @Published var engine = Prefs.engine { didSet { Prefs.engine = engine } }
    @Published var style = Prefs.style { didSet { Prefs.style = style } }
    @Published var useAX = Prefs.useAccessibility { didSet { Prefs.useAccessibility = useAX } }
    @Published var accurate = Prefs.accurateOCR { didSet { Prefs.accurateOCR = accurate } }
    @Published var web = Prefs.webOptimize { didSet { Prefs.webOptimize = web } }
    @Published var follow = Prefs.followScroll { didSet { Prefs.followScroll = follow } }
    @Published var hover = Prefs.hoverWithOption { didSet { Prefs.hoverWithOption = hover; HoverWatcher.shared.update() } }
    @Published var cloudKey = Prefs.googleCloudKey { didSet { Prefs.googleCloudKey = cloudKey } }
    @Published var deeplKey = Prefs.deeplKey { didSet { Prefs.deeplKey = deeplKey } }
    @Published var ollamaURL = Prefs.ollamaURL { didSet { Prefs.ollamaURL = ollamaURL } }
    @Published var ollamaModel = Prefs.ollamaModel { didSet { Prefs.ollamaModel = ollamaModel } }
    @Published var login = Permissions.launchAtLogin { didSet { if login != Permissions.launchAtLogin { Permissions.launchAtLogin = login } } }
    @Published var offlineSource = "ja"
    @Published var localModel = Prefs.localModel { didSet { Prefs.localModel = localModel } }
    @Published var appleFast = Prefs.appleFast { didSet { Prefs.appleFast = appleFast } }
    @Published var screenOK = Capture.hasPermission
    @Published var axOK = AXText.trusted
    @Published var recording: Action?
    @Published var tick = 0

    func refresh() {
        screenOK = Capture.hasPermission
        axOK = AXText.trusted
        tick += 1
    }
}

struct SettingsView: View {
    @ObservedObject var m: SettingsModel
    let only: SettingsWindow.Tab
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        switch only {
        case .general: general
        case .shortcuts: shortcuts
        case .models: ModelsView(m: m)
        case .voices: VoicesView(m: m)
        case .engines: engines
        case .permissions: permissions.onReceive(poll) { _ in m.refresh() }
        }
    }

    private var general: some View {
        Form {
            Picker("Translate into", selection: $m.target) {
                ForEach(Language.all) { Text($0.name).tag($0.code) }
            }
            Picker("Look", selection: $m.style) {
                ForEach(OverlayStyle.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Read app text directly (Accessibility) for exact, native-looking results", isOn: $m.useAX)
            Toggle("Keep translating while you scroll and use the app", isOn: $m.follow)
            Toggle("Translate web pages by paragraph (any browser)", isOn: $m.web)
            Toggle("Accurate text recognition (slower, better for small text)", isOn: $m.accurate)
            Toggle("Hold ⌥ and rest the pointer on text to translate it", isOn: $m.hover)
            Toggle("Open at login", isOn: $m.login)
            Section {
                Text("While a translation is showing: hold ⌥ to see the original, hover a block to read its original, right-click to copy, click or press Esc to close.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Show Tutorial") { Tips.reset(); Tutorial.show() }
            }
        }
        .formStyle(.grouped)
    }

    private var shortcuts: some View {
        Form {
            ForEach(Action.allCases, id: \.self) { a in
                LabeledContent(a.title) { ShortcutRecorder(action: a, m: m) }
            }
            Text("Live translation stops with the same shortcut or ⌥Esc.").font(.callout).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var engines: some View {
        Form {
            Picker("Engine", selection: $m.engine) {
                ForEach(EngineKind.allCases) { Text($0.title).tag($0) }
            }
            Section("Your own keys (optional)") {
                SecureField("Google Cloud API key", text: $m.cloudKey)
                SecureField("DeepL API key", text: $m.deeplKey)
            }
            Section("Ollama") {
                TextField("Server", text: $m.ollamaURL)
                TextField("Model", text: $m.ollamaModel)
            }
        }
        .formStyle(.grouped)
    }

    private var permissions: some View {
        Form {
            row("Screen Recording", ok: m.screenOK, why: "Needed to see the text on screen.") {
                CGRequestScreenCaptureAccess()
                Permissions.openPrivacy("Privacy_ScreenCapture")
            }
            row("Accessibility", ok: m.axOK, why: "Optional. Reads app text directly for exact positions and fonts, and enables translating a selection.") {
                AXText.requestTrust()
                Permissions.openPrivacy("Privacy_Accessibility")
            }
            if !m.screenOK {
                Text("After allowing Screen Recording, macOS may ask to quit and reopen Lingveil.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ title: String, ok: Bool, why: String, grant: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).bold()
                Text(why).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if !ok { Button("Allow…", action: grant) }
        }
    }
}

struct ShortcutRecorder: View {
    let action: Action
    @ObservedObject var m: SettingsModel
    @State private var monitor: Any?

    var body: some View {
        let _ = m.tick
        HStack(spacing: 6) {
            Button(m.recording == action ? "Type shortcut…" : (Prefs.shortcut(action)?.display ?? "None")) {
                m.recording == action ? stop() : start()
            }
            .frame(minWidth: 110)
            if Prefs.shortcut(action) != nil {
                Button { Prefs.setShortcut(nil, for: action); apply() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
        }
    }

    private func start() {
        m.recording = action
        (NSApp.delegate as? AppDelegate)?.unregisterShortcuts()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == UInt16(kVK_Escape) { stop(); return nil }
            if let s = Shortcut(event: e) { Prefs.setShortcut(s, for: action); stop() }
            return nil
        }
    }

    private func stop() {
        if let mon = monitor { NSEvent.removeMonitor(mon); monitor = nil }
        m.recording = nil
        apply()
    }

    private func apply() {
        (NSApp.delegate as? AppDelegate)?.registerShortcuts()
        m.tick += 1
    }
}
