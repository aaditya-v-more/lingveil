import SwiftUI
import Carbon.HIToolbox

@MainActor
enum SettingsWindow {
    enum Tab: String { case general, shortcuts, models, engines, permissions }
    private static var window: NSWindow?
    private static let model = SettingsModel()

    static func show(tab: Tab = .general) {
        model.tab = tab
        model.refresh()
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 600),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Lingveil"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(m: model))
            w.center()
            window = w
        }
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
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        TabView(selection: $m.tab) {
            general.tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsWindow.Tab.general)
            shortcuts.tabItem { Label("Shortcuts", systemImage: "command") }.tag(SettingsWindow.Tab.shortcuts)
            ModelsView(m: m).tabItem { Label("Models", systemImage: "cpu") }.tag(SettingsWindow.Tab.models)
            engines.tabItem { Label("Online", systemImage: "globe") }.tag(SettingsWindow.Tab.engines)
            permissions.tabItem { Label("Permissions", systemImage: "lock.shield") }.tag(SettingsWindow.Tab.permissions)
        }
        .padding(16)
        .frame(width: 640, height: 600)
        .onReceive(poll) { _ in if m.tab == .permissions { m.refresh() } }
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
            Toggle("Accurate text recognition (slower, better for small text)", isOn: $m.accurate)
            Toggle("Hold ⌥ and rest the pointer on text to translate it", isOn: $m.hover)
            Toggle("Open at login", isOn: $m.login)
            Section {
                Text("While a translation is showing: hold ⌥ to see the original, hover a block to read its original, right-click to copy, click or press Esc to close.")
                    .font(.callout).foregroundStyle(.secondary)
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
