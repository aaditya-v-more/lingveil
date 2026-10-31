import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var registered: [UInt32] = []

    func applicationDidFinishLaunching(_ n: Notification) {
        if Debug.runIfRequested() { return }
        Debug.listenIfRequested()
        StatusIcon.install(menu: makeMenu())
        registerShortcuts()
        HoverWatcher.shared.update()
        Task.detached(priority: .utility) { await OCRHelper.shared.warmUp() }
        if !UserDefaults.standard.bool(forKey: "onboarded") {
            UserDefaults.standard.set(true, forKey: "onboarded")
            SettingsWindow.show(tab: .permissions)
            if !Capture.hasPermission { CGRequestScreenCaptureAccess() }
            if Prefs.useAccessibility { Permissions.ensureAccessibility() }
        }
    }

    func registerShortcuts() {
        registered.forEach { HotKeys.shared.unregister($0) }
        registered = Action.allCases.compactMap { a in
            guard let s = Prefs.shortcut(a) else { return nil }
            let id = HotKeys.shared.register(s) { [weak self] in self?.perform(a) }
            Debug.log("shortcut \(a.rawValue) \(s.display) \(id == nil ? "FAILED" : "registered")")
            return id
        }
    }

    func unregisterShortcuts() {
        registered.forEach { HotKeys.shared.unregister($0) }
        registered = []
    }

    func perform(_ a: Action) {
        Debug.log("action \(a.rawValue)")
        switch a {
        case .screen: OneShot.shared.toggleScreen()
        case .area: OneShot.shared.area()
        case .live: Live.shared.toggle()
        case .cursor: Bubble.shared.underPointer()
        case .selection: Bubble.shared.selection()
        }
    }

    // MARK: menu

    private func makeMenu() -> NSMenu {
        let m = NSMenu()
        m.delegate = self
        return m
    }

    func menuNeedsUpdate(_ m: NSMenu) {
        m.removeAllItems()
        for a in Action.allCases {
            let title = a == .live && Live.shared.isRunning ? "Stop Live Translation" : a.title
            let item = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: "")
            item.representedObject = a.rawValue
            if let s = Prefs.shortcut(a) { item.keyEquivalent = s.menuKey; item.keyEquivalentModifierMask = s.menuModifiers }
            m.addItem(item)
            if a == .live { m.addItem(.separator()) }
        }
        m.addItem(.separator())

        let target = NSMenuItem(title: "Translate Into: \(Language.named(Prefs.target).name)", action: nil, keyEquivalent: "")
        let tm = NSMenu()
        for l in Language.all {
            let i = NSMenuItem(title: l.name, action: #selector(pickTarget(_:)), keyEquivalent: "")
            i.representedObject = l.code
            i.state = l.code == Prefs.target ? .on : .off
            tm.addItem(i)
        }
        target.submenu = tm
        m.addItem(target)

        let engine = NSMenuItem(title: "Engine", action: nil, keyEquivalent: "")
        let em = NSMenu()
        for e in EngineKind.allCases {
            let i = NSMenuItem(title: e.title, action: #selector(pickEngine(_:)), keyEquivalent: "")
            i.representedObject = e.rawValue
            i.state = e == Prefs.engine ? .on : .off
            em.addItem(i)
        }
        engine.submenu = em
        m.addItem(engine)

        if !Capture.hasPermission || (Prefs.useAccessibility && !AXText.trusted) {
            m.addItem(.separator())
            let p = NSMenuItem(title: "Finish Setting Up Permissions…", action: #selector(openPermissions), keyEquivalent: "")
            p.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            m.addItem(p)
        }
        m.addItem(.separator())
        m.addItem(withTitle: "About Lingveil", action: #selector(about), keyEquivalent: "")
        m.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        m.addItem(withTitle: "Quit Lingveil", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for i in m.items where i.action != #selector(NSApplication.terminate(_:)) { i.target = self }
        for i in tm.items + em.items { i.target = self }
    }

    @objc private func menuAction(_ i: NSMenuItem) {
        guard let a = Action(rawValue: i.representedObject as? String ?? "") else { return }
        // Let the menu close before capturing the screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.perform(a) }
    }
    @objc private func pickTarget(_ i: NSMenuItem) { Prefs.target = i.representedObject as? String ?? Prefs.target }
    @objc private func pickEngine(_ i: NSMenuItem) { Prefs.engine = EngineKind(rawValue: i.representedObject as? String ?? "") ?? .auto }
    @objc private func openSettings() { SettingsWindow.show() }
    @objc private func about() { NSApp.activate(ignoringOtherApps: true); NSApp.orderFrontStandardAboutPanel(nil) }
    @objc private func openPermissions() { SettingsWindow.show(tab: .permissions) }
}

@MainActor
enum StatusIcon {
    private static var item: NSStatusItem?
    private static var isBusy = false, isLive = false

    static func install(menu: NSMenu) {
        let i = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        i.menu = menu
        item = i
        refresh()
    }

    static func busy(_ b: Bool) { isBusy = b; refresh() }
    static func live(_ b: Bool) { isLive = b; refresh() }

    private static func refresh() {
        let name = isBusy ? "ellipsis.bubble" : isLive ? "character.bubble.fill" : "character.bubble"
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Lingveil")
        img?.isTemplate = true
        item?.button?.image = img
    }
}

@MainActor
enum Permissions {
    /// Returns true when screen capture is allowed; otherwise asks and opens Settings.
    @discardableResult
    static func ensureScreenCapture() -> Bool {
        if Capture.hasPermission { return true }
        CGRequestScreenCaptureAccess()
        SettingsWindow.show(tab: .permissions)
        return false
    }

    static func ensureAccessibility() {
        if AXText.trusted { return }
        AXText.requestTrust()
    }

    static func openPrivacy(_ anchor: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }

    static var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set { try? newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
    }
}

@MainActor
enum Alerts {
    static func show(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}
