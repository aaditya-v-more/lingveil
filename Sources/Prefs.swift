import AppKit
import Carbon.HIToolbox

/// Every user setting, backed by UserDefaults. Read on demand so changes made in the
/// settings window take effect on the next translation without any wiring.
enum Prefs {
    static let d = UserDefaults.standard

    static var target: String {
        get { ProcessInfo.processInfo.environment["LINGVEIL_TARGET"] ?? d.string(forKey: "target") ?? Language.systemDefault.code }
        set { d.set(newValue, forKey: "target") }
    }
    static var engine: EngineKind {
        get { EngineKind(rawValue: ProcessInfo.processInfo.environment["LINGVEIL_ENGINE"] ?? d.string(forKey: "engine") ?? "") ?? .auto }
        set { d.set(newValue.rawValue, forKey: "engine") }
    }
    static var style: OverlayStyle {
        get { OverlayStyle(rawValue: d.string(forKey: "style") ?? "") ?? .seamless }
        set { d.set(newValue.rawValue, forKey: "style") }
    }
    static var useAccessibility: Bool {
        get { d.object(forKey: "useAX") as? Bool ?? true }
        set { d.set(newValue, forKey: "useAX") }
    }
    /// Translate web pages paragraph by paragraph (any browser or web-based app).
    static var webOptimize: Bool {
        get { d.object(forKey: "webOptimize") as? Bool ?? true }
        set { d.set(newValue, forKey: "webOptimize") }
    }
    /// Keep a translation in place while the app scrolls and changes (like Pixel phones).
    static var followScroll: Bool {
        get { d.object(forKey: "followScroll") as? Bool ?? true }
        set { d.set(newValue, forKey: "followScroll") }
    }
    static var accurateOCR: Bool {
        get { d.object(forKey: "accurateOCR") as? Bool ?? true }
        set { d.set(newValue, forKey: "accurateOCR") }
    }
    static var hoverWithOption: Bool {
        get { d.bool(forKey: "hoverWithOption") }
        set { d.set(newValue, forKey: "hoverWithOption") }
    }
    static var googleCloudKey: String {
        get { d.string(forKey: "googleCloudKey") ?? "" }
        set { d.set(newValue, forKey: "googleCloudKey") }
    }
    static var deeplKey: String {
        get { d.string(forKey: "deeplKey") ?? "" }
        set { d.set(newValue, forKey: "deeplKey") }
    }
    static var localModel: String {
        get { ProcessInfo.processInfo.environment["LINGVEIL_LOCAL_MODEL"] ?? d.string(forKey: "localModel") ?? "index-translate-2b" }
        set { d.set(newValue, forKey: "localModel") }
    }
    /// Apple's smaller on-device models (macOS 26.4+): much faster, a little less polished.
    static var appleFast: Bool {
        get { d.object(forKey: "appleFast") as? Bool ?? true }
        set { d.set(newValue, forKey: "appleFast") }
    }
    /// Read-aloud speed, 1 = normal.
    static var speechSpeed: Double {
        get { d.object(forKey: "speechSpeed") as? Double ?? 1.0 }
        set { d.set(newValue, forKey: "speechSpeed") }
    }
    /// "system" (macOS voices), a voice plugin's name, or "model:<id>" for a narration model.
    static var voiceEngine: String {
        get { d.string(forKey: "voiceEngine") ?? "system" }
        set { d.set(newValue, forKey: "voiceEngine") }
    }
    static func voiceID(for key: String) -> String? { d.string(forKey: "voice." + key) }
    static func setVoiceID(_ id: String?, for key: String) { d.set(id, forKey: "voice." + key) }

    static var ollamaURL: String {
        get { d.string(forKey: "ollamaURL") ?? "http://localhost:11434" }
        set { d.set(newValue, forKey: "ollamaURL") }
    }
    static var ollamaModel: String {
        get { d.string(forKey: "ollamaModel") ?? "qwen3:4b" }
        set { d.set(newValue, forKey: "ollamaModel") }
    }

    static func shortcut(_ a: Action) -> Shortcut? {
        if let s = d.string(forKey: "key." + a.rawValue) { return s.isEmpty ? nil : Shortcut(string: s) }
        return a.defaultShortcut
    }
    static func setShortcut(_ s: Shortcut?, for a: Action) {
        d.set(s?.string ?? "", forKey: "key." + a.rawValue)
    }
}

enum EngineKind: String, CaseIterable, Identifiable {
    case auto, google, local, apple, googleCloud, deepl, ollama
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: "Automatic"
        case .google: "Google Translate"
        case .local: "Local Model"
        case .apple: "Apple Translation"
        case .googleCloud: "Google Cloud"
        case .deepl: "DeepL"
        case .ollama: "Ollama"
        }
    }
}

enum OverlayStyle: String, CaseIterable, Identifiable {
    case seamless, card
    var id: String { rawValue }
    var title: String { self == .seamless ? "Seamless (matches the app)" : "Cards (rounded, readable)" }
}

enum Action: String, CaseIterable {
    case screen, area, live, cursor, selection, read, translateRead
    var title: String {
        switch self {
        case .screen: "Translate Screen"
        case .area: "Translate Area…"
        case .live: "Live Translate Area…"
        case .cursor: "Translate Under Pointer"
        case .selection: "Translate Selected Text"
        case .read: "Read Aloud"
        case .translateRead: "Translate and Read Aloud"
        }
    }
    var defaultShortcut: Shortcut? {
        let m = UInt32(optionKey | shiftKey)
        switch self {
        case .screen: return Shortcut(key: UInt32(kVK_ANSI_T), mods: m)
        case .area: return Shortcut(key: UInt32(kVK_ANSI_A), mods: m)
        case .live: return Shortcut(key: UInt32(kVK_ANSI_L), mods: m)
        case .cursor: return Shortcut(key: UInt32(kVK_ANSI_D), mods: m)
        case .selection: return Shortcut(key: UInt32(kVK_ANSI_S), mods: m)
        case .read: return Shortcut(key: UInt32(kVK_ANSI_R), mods: m)
        case .translateRead: return Shortcut(key: UInt32(kVK_ANSI_E), mods: m)
        }
    }
}

/// A target language, from shared/languages.json (shared with the Windows app).
struct Language: Hashable, Identifiable, Decodable {
    let code: String         // Google-style code
    let name: String
    let appleId: String      // BCP-47 id for Apple Translation and NaturalLanguage
    let chineseName: String  // used in Index-Translate prompts
    var id: String { code }
    var appleID: String { appleId }

    static let all: [Language] = {
        struct File: Decodable { let languages: [Language] }
        guard let url = Bundle.main.url(forResource: "languages", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { fatalError("languages.json missing from the app bundle") }
        return file.languages
    }()

    static func named(_ code: String) -> Language {
        all.first { $0.code == code } ?? Language(code: code, name: code, appleId: code, chineseName: code)
    }

    static var systemDefault: Language {
        let id = Locale.preferredLanguages.first ?? "en"
        if id.hasPrefix("zh") { return named(id.contains("Hant") || id.contains("TW") || id.contains("HK") ? "zh-TW" : "zh-CN") }
        let base = String(id.prefix { $0 != "-" })
        return all.first { $0.code == base || $0.appleID == base } ?? named("en")
    }
}

struct Shortcut: Equatable {
    var key: UInt32
    var mods: UInt32   // Carbon modifier mask

    init(key: UInt32, mods: UInt32) { self.key = key; self.mods = mods }
    init?(string: String) {
        let p = string.split(separator: ":").compactMap { UInt32($0) }
        guard p.count == 2 else { return nil }
        key = p[0]; mods = p[1]
    }
    var string: String { "\(key):\(mods)" }

    init?(event: NSEvent) {
        var m: UInt32 = 0
        let f = event.modifierFlags
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        guard m & UInt32(cmdKey | optionKey | controlKey) != 0 else { return nil }
        self.init(key: UInt32(event.keyCode), mods: m)
    }

    var display: String {
        var s = ""
        if mods & UInt32(controlKey) != 0 { s += "⌃" }
        if mods & UInt32(optionKey) != 0 { s += "⌥" }
        if mods & UInt32(shiftKey) != 0 { s += "⇧" }
        if mods & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + Shortcut.keyName(key)
    }

    var menuModifiers: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if mods & UInt32(controlKey) != 0 { f.insert(.control) }
        if mods & UInt32(optionKey) != 0 { f.insert(.option) }
        if mods & UInt32(shiftKey) != 0 { f.insert(.shift) }
        if mods & UInt32(cmdKey) != 0 { f.insert(.command) }
        return f
    }

    var menuKey: String { Shortcut.keyName(key).lowercased() }

    static func keyName(_ code: UInt32) -> String {
        let special: [Int: String] = [kVK_Space: "Space", kVK_Return: "↩", kVK_Escape: "⎋", kVK_Tab: "⇥",
                                      kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
                                      kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10"]
        if let s = special[Int(code)] { return s }
        guard let src = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var len = 0
        data.withUnsafeBytes { raw in
            let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress!
            UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                           OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
        }
        return String(utf16CodeUnits: chars, count: len).uppercased()
    }
}
