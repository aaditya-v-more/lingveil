import AppKit

/// Copy Text from Area (⌥⇧C): drag over any part of the screen and its text goes on the
/// clipboard as plain, editable text. Uses the app's own text where accessibility has it
/// (exact characters), otherwise recognizes it from the pixels, and keeps the reading order
/// and line breaks.
@MainActor
enum CopyText {
    private(set) static var last: String?

    static func area() {
        guard Permissions.ensureScreenCapture() else { return }
        let app = Pipeline.frontApp
        last = nil
        Task {
            guard let (screen, rect) = await RegionPicker.pick() else { return }
            StatusIcon.busy(true)
            defer { StatusIcon.busy(false) }
            guard let snap = try? await Capture.snapshot(screen, rect: rect) else { Alerts.flash("Couldn't capture the screen"); return }
            let items = await Pipeline.items(in: snap, app: app).filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !items.isEmpty else { Alerts.flash("No text found there"); return }
            let text = arrange(items)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            last = text
            let lines = text.split(separator: "\n").count
            Alerts.flash(lines == 1 ? "Copied: \(text.prefix(40))\(text.count > 40 ? "…" : "")" : "Copied \(lines) lines of text")
            Support.used()
        }
    }

    /// Items in reading order. A gap bigger than a line between blocks becomes a blank line;
    /// blocks side by side on one row are joined with a tab (table cells, columns of a form).
    static func arrange(_ items: [TextItem]) -> String {
        let order = ReadingOrder.order(items.map(\.rect))
        var out = ""
        var prev: CGRect?
        for i in order {
            let it = items[i]
            if let p = prev {
                let sameRow = abs(p.midY - it.rect.midY) < min(p.height, it.rect.height) * 0.5 && it.rect.minX > p.maxX
                if sameRow { out += "\t" }
                else { out += (p.minY - it.rect.maxY > max(it.lineHeight, 8) * 1.2) ? "\n\n" : "\n" }
            }
            out += it.text
            prev = it.rect
        }
        return out
    }
}
