import SwiftUI
import AVFoundation

/// Settings → Voices: what reads aloud, how fast, and which voice per language.
struct VoicesView: View {
    @ObservedObject var m: SettingsModel
    @ObservedObject private var store = VoiceStore.shared
    @State private var confirmDelete: VoiceModel?
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
                    ForEach(VoiceCatalog.shared.models.filter { store.installed.contains($0.id) }) { Text($0.name).tag("model:" + $0.id) }
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
                if engine == "system" { systemVoices }
                else if let p = plugins.first(where: { $0.name == engine }) { pluginVoices(p) }
                else if let v = VoiceCatalog.shared.models.first(where: { "model:" + $0.id == engine }) { modelVoice(v) }
            } header: {
                Text("Voice for \(target.name)")
            } footer: {
                Text("Text in other languages is read with the best voice installed for that language. Change the target language in General.")
            }
            if LocalModel.isAppleSilicon {
                Section {
                    ForEach(VoiceCatalog.shared.models.filter(\.recommended)) { modelRow($0) }
                } header: {
                    Text("Voices that run on this Mac")
                } footer: {
                    Text("Open-source voices, downloaded once and run offline. Ratings are measured: speed from how long a sentence takes to make, clarity from how well a speech recognizer understands it.")
                }
                Section("More voices") {
                    ForEach(VoiceCatalog.shared.models.filter { !$0.recommended }) { modelRow($0) }
                }
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
        .onChange(of: store.installed) { _, now in
            if engine.hasPrefix("model:"), !now.contains(String(engine.dropFirst(6))) { engine = "system" }
        }
        .confirmationDialog("Delete \(confirmDelete?.name ?? "")?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete \(confirmDelete?.sizeText ?? "")", role: .destructive) { if let v = confirmDelete { store.delete(v) }; confirmDelete = nil }
        } message: { Text("You can download it again later.") }
    }

    @ViewBuilder private func modelVoice(_ v: VoiceModel) -> some View {
        HStack {
            if let m = NarrationModels.model(for: base, preferring: v) {
                Text(m.id == v.id ? "\(v.name) reads \(target.name)." : "\(v.name) has no \(target.name) voice; \(m.name) reads it.")
            } else {
                Text("\(v.name) has no \(target.name) voice; Apple's voice is used instead.").foregroundStyle(.secondary)
            }
            Spacer()
            Button { preview() } label: { Image(systemName: "play.fill") }.help("Hear it")
        }
    }

    @ViewBuilder private func modelRow(_ v: VoiceModel) -> some View {
        let installed = store.installed.contains(v.id)
        let inUse = engine == "model:" + v.id
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(v.name).font(.headline)
                Text(v.maker).foregroundStyle(.secondary)
                if let b = v.badge, v.recommended { Tag(text: b, color: .green) }
                if v.tested && !v.recommended { Tag(text: "Tested", color: .secondary) }
                if inUse { Tag(text: "In use", color: .accentColor) }
                Spacer()
                if let p = store.progress[v.id] {
                    ProgressView(value: p).frame(width: 70)
                    Button("Cancel") { store.cancel(v) }
                } else if installed {
                    if !inUse { Button { engine = "model:" + v.id } label: { Text("Use").frame(minWidth: 70) } }
                    Button(role: .destructive) { confirmDelete = v } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("Delete \(v.name) (\(v.sizeText))")
                } else {
                    Button { store.download(v) } label: { Text("Download").frame(minWidth: 70) }
                }
            }
            Text(v.summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 18) {
                Rating(label: "Speed", value: v.speed)
                Rating(label: "Clarity", value: v.clarity)
                Text("\(v.sizeText) · \(languageList(v)) · \(v.license)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if let e = store.errors[v.id] { Text(e).font(.caption).foregroundStyle(.red) }
        }
        .padding(.vertical, 4)
    }

    private func languageList(_ v: VoiceModel) -> String {
        if v.languages.count > 4 { return "\(v.languages.count) languages" }
        return v.languages.map { c in Language.all.first { $0.code == c }?.name ?? c }.joined(separator: ", ")
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
