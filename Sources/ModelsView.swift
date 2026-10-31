import SwiftUI
import Translation

/// Settings → Models: pick how translation runs, and download local models. Models we
/// have measured come first with their speed and accuracy ratings.
struct ModelsView: View {
    @ObservedObject var m: SettingsModel
    @ObservedObject private var store = ModelStore.shared
    @State private var confirmDelete: LocalModel?

    private var target: Language { Language.named(m.target) }

    var body: some View {
        Form {
            Section {
                Picker("Translate with", selection: $m.engine) {
                    ForEach(EngineKind.allCases) { Text($0.title).tag($0) }
                }
                Text(engineNote).font(.callout).foregroundStyle(.secondary)
            }
            if LocalModel.isAppleSilicon {
                Section {
                    ForEach(LocalModel.catalog.filter(\.recommended)) { row($0) }
                } header: {
                    Text("Recommended · tested on Macs with 8 GB")
                } footer: {
                    Text("Ratings are measured: speed from time per line, accuracy from how close the output is to Google Translate (chrF), on real app text. Models run only on this Mac; nothing you translate leaves it.")
                }
            }
            Section("Built into macOS") {
                appleRow(fast: true)
                appleRow(fast: false)
                HStack {
                    Picker("Language pair", selection: $m.offlineSource) {
                        ForEach(Language.all.filter { $0.code != m.target }) { Text("\($0.name) → \(target.name)").tag($0.appleID) }
                    }
                    LanguageDownloadButton(source: m.offlineSource, target: target.appleID, fast: m.appleFast)
                }
            }
            if LocalModel.isAppleSilicon {
                Section {
                    ForEach(LocalModel.catalog.filter { !$0.recommended }) { row($0) }
                } header: {
                    Text("More models")
                } footer: {
                    Text("Ratings on models marked Tested come from our tests; the others are estimates from the makers' published results and model size.")
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete \(confirmDelete?.name ?? "")?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete \(confirmDelete?.sizeText ?? "")", role: .destructive) { if let m = confirmDelete { store.delete(m) }; confirmDelete = nil }
        } message: { Text("You can download it again later.") }
    }

    private var engineNote: String {
        switch m.engine {
        case .auto: "Uses Google Translate when online. Offline, it switches to the local model you pick below, or to Apple's."
        case .local: "Everything is translated on this Mac with the model you pick below."
        case .apple: "Uses the translation models built into macOS. Each language pair is downloaded once."
        case .google: "Uses Google Translate. Needs an internet connection."
        default: "Set up in the Online tab."
        }
    }

    @ViewBuilder
    private func row(_ model: LocalModel) -> some View {
        let installed = store.isInstalled(model)
        let selected = m.localModel == model.id
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.name).font(.headline)
                Text(model.maker).foregroundStyle(.secondary)
                if let b = model.badge { Tag(text: b, color: .green) }
                if model.tested && !model.recommended { Tag(text: "Tested", color: .secondary) }
                if selected && installed { Tag(text: "In use", color: .accentColor) }
                Spacer()
                actions(model, installed: installed, selected: selected)
            }
            Text(model.summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 18) {
                Rating(label: "Speed", value: model.speed)
                Rating(label: "Accuracy", value: model.accuracy)
                Text("\(model.sizeText) · \(model.ramGB) GB Mac · \(model.languages) languages · \(model.license)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.ramGB > LocalModel.macRAMGB {
                Label("Needs a Mac with \(model.ramGB) GB of memory; this one has \(LocalModel.macRAMGB) GB.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            } else if !model.supports(target) {
                Label("Can't translate into \(target.name).", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let p = store.progress[model.id] {
                ProgressView(value: p) { EmptyView() } currentValueLabel: {
                    Text("\(Int(p * 100))% of \(model.sizeText)").font(.caption)
                }
            }
            if let e = store.errors[model.id] { Text(e).font(.caption).foregroundStyle(.red) }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func actions(_ model: LocalModel, installed: Bool, selected: Bool) -> some View {
        if store.verifying.contains(model.id) {
            Text("Checking…").font(.callout).foregroundStyle(.secondary)
        } else if store.progress[model.id] != nil {
            Button("Cancel") { store.cancel(model) }
        } else if installed {
            HStack(spacing: 8) {
                if !selected {
                    Button { m.localModel = model.id; if m.engine != .auto { m.engine = .local } } label: { Text("Use").frame(minWidth: 70) }
                }
                Button(role: .destructive) { confirmDelete = model } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("Delete \(model.name) (\(model.sizeText))")
            }
        } else {
            Button { store.download(model); if !store.installed.contains(m.localModel) { m.localModel = model.id } } label: { Text("Download").frame(minWidth: 70) }
                .disabled(model.ramGB > max(LocalModel.macRAMGB, 8) * 2)
        }
    }

    @ViewBuilder
    private func appleRow(fast: Bool) -> some View {
        let available: Bool = { if #available(macOS 26.4, *) { return true } else { return false } }()
        if fast && !available { EmptyView() } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(fast ? "Apple Translation · Fast" : "Apple Translation · High quality").font(.headline)
                    Text("Apple").foregroundStyle(.secondary)
                    if m.appleFast == fast { Tag(text: "Preferred", color: .accentColor) }
                    Spacer()
                    if m.appleFast != fast && available { Button("Prefer") { m.appleFast = fast } }
                }
                Text(fast ? "Apple's compact models: quick enough for whole screens, with slightly plainer wording."
                          : "The same models as the Translate app. Polished wording, but a full screen of text can take several seconds.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 18) {
                    // The fast models haven't been through our tests yet (they need a per-pair download).
                    let r = Catalog.shared.appleRatings?[fast ? "fast" : "highQuality"]
                    Rating(label: "Speed", value: r?["speed"] ?? 0)
                    Rating(label: "Accuracy", value: r?["accuracy"] ?? 0)
                    Text("Built in · runs outside Lingveil · ~20 languages").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

struct Rating: View {
    let label: String
    let value: Int
    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Group {
                if value == 0 { Text("not rated").font(.caption).foregroundStyle(.tertiary) } else {
                    HStack(spacing: 2) {
                        ForEach(1...5, id: \.self) { i in
                            Capsule().fill(i <= value ? Color.accentColor : Color.primary.opacity(0.18)).frame(width: 9, height: 5)
                        }
                    }
                }
            }
            .frame(width: 56, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(value == 0 ? "\(label) not rated yet" : "\(label) \(value) out of 5")
    }
}

struct Tag: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.22), in: Capsule()).foregroundStyle(color)
    }
}
