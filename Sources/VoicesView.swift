import SwiftUI
import AVFoundation

/// Settings → Voices: what reads aloud, how fast, and which voice per language.
struct VoicesView: View {
    @ObservedObject var m: SettingsModel
    @State private var engine = Prefs.voiceEngine
    @State private var speed = Prefs.speechSpeed
    @State private var plugins = Plugins.load()
    @State private var installing = false
    @State private var installLog = ""
    @State private var refresh = 0

    private var target: Language { Language.named(m.target) }
    private var base: String { String(target.appleID.prefix { $0 != "-" }) }
    private var googleInstalled: Bool { plugins.contains { $0.name == "Google" } }

    var body: some View {
        Form {
            Section {
                Picker("Read with", selection: $engine) {
                    Text("Apple voices").tag("system")
                    ForEach(plugins, id: \.name) { Text("\($0.name) voices").tag($0.name) }
                }
                .onChange(of: engine) { _, v in Prefs.voiceEngine = v }
                HStack {
                    Text("Speed")
                    Slider(value: $speed, in: 0.5...3, step: 0.1) { Text("Speed") } minimumValueLabel: { Image(systemName: "tortoise") } maximumValueLabel: { Image(systemName: "hare") }
                        .labelsHidden()
                        .onChange(of: speed) { _, v in Prefs.speechSpeed = v }
                    Text(String(format: "%.1f×", speed)).monospacedDigit().frame(width: 40, alignment: .trailing)
                }
            }
            Section {
                if engine == "system" { systemVoices } else if let p = plugins.first(where: { $0.name == engine }) { pluginVoices(p) }
            } header: {
                Text("Voice for \(target.name)")
            } footer: {
                Text("Text in other languages is read with the best voice installed for that language. Change the target language in General.")
            }
            Section("Google voices") {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Google's own on-device voices, the same ones Android uses, running natively on this Mac.")
                        Text(googleInstalled ? "Installed." : "Needs Homebrew and an Apple silicon Mac; downloads about 110 MB from Google.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(googleInstalled ? "Update" : "Install") { install() }.disabled(installing)
                }
                if installing || !installLog.isEmpty {
                    Text(installLog).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(3)
                    if installing { ProgressView().controlSize(.small) }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var systemVoices: some View {
        let voices = Voices.systemVoices(for: base)
        let chosen = Binding<String>(
            get: { _ = refresh; return Prefs.voiceID(for: base) ?? Voices.systemVoice(for: target.appleID)?.identifier ?? "" },
            set: { Prefs.setVoiceID($0, for: base); refresh += 1 })
        if voices.isEmpty {
            Text("No \(target.name) voice is installed.").foregroundStyle(.secondary)
        } else {
            HStack {
                Picker("Voice", selection: chosen) {
                    ForEach(voices, id: \.identifier) { v in Text("\(v.name)  \(quality(v.quality))").tag(v.identifier) }
                }
                Button { preview() } label: { Image(systemName: "play.fill") }.help("Hear it")
            }
        }
        Button("Add Higher-Quality Voices…") {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent")!)
        }
        .buttonStyle(.link)
    }

    @ViewBuilder private func pluginVoices(_ p: PluginConfig) -> some View {
        let voices = Plugins.voices(p).filter { $0.language.lowercased().hasPrefix(base) }
        let key = "\(p.name)|\(base)"
        let chosen = Binding<String>(
            get: { _ = refresh; return Prefs.voiceID(for: key) ?? Voices.pluginVoice(p, language: base) ?? "" },
            set: { Prefs.setVoiceID($0, for: key); refresh += 1 })
        if voices.isEmpty {
            Text("\(p.name) has no \(target.name) voice; Apple's voice is used instead.").foregroundStyle(.secondary)
        } else {
            HStack {
                Picker("Voice", selection: chosen) {
                    ForEach(voices, id: \.id) { v in Text("\(v.name) (\(v.language)\(v.gender.map { ", " + $0 } ?? ""))").tag(v.id) }
                }
                Button { preview() } label: { Image(systemName: "play.fill") }.help("Hear it")
            }
        }
    }

    private func quality(_ q: AVSpeechSynthesisVoiceQuality) -> String {
        switch q { case .premium: "Premium"; case .enhanced: "Enhanced"; default: "" }
    }

    private func preview() {
        let sample = [
            "en": "This is how Lingveil reads your screen aloud.", "hi": "लिंगवील आपकी स्क्रीन इसी तरह पढ़कर सुनाता है।",
            "ja": "Lingveil は画面をこのように読み上げます。", "es": "Así es como Lingveil lee tu pantalla en voz alta.",
            "fr": "Voici comment Lingveil lit votre écran à voix haute.", "de": "So liest Lingveil deinen Bildschirm vor.",
            "zh": "Lingveil 会这样朗读你的屏幕。", "ko": "Lingveil은 화면을 이렇게 읽어 줍니다.",
        ][base] ?? "Lingveil"
        Narrator.shared.read([Segment(text: sample, rect: nil, language: target.appleID)]) { _ in }
    }

    private func install() {
        installing = true; installLog = "Starting…"
        Task {
            let ok = await Plugins.installGoogle { installLog = $0 }
            installing = false
            plugins = Plugins.load()
            installLog = ok ? "Google voices are ready." : (installLog.isEmpty ? "Install failed." : installLog)
            if ok { engine = "Google" }
        }
    }
}
