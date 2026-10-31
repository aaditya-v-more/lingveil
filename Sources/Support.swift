import AppKit

/// Ko-fi links, and a rare, polite reminder for people who use Lingveil a lot.
///
/// The reminder only appears for frequent users (30+ uses on 5+ different days), at a
/// quiet moment (after a translation or reading finishes, never during one), at most once a
/// month, and "Don't show for 2 months" pauses it for 60 days. After an update, a short
/// "Updated" note mentions it too.
@MainActor
enum Support {
    static let url = URL(string: "https://ko-fi.com/aadityavmore")!
    private static let d = UserDefaults.standard
    private static var panel: NSPanel?

    static func open() { NSWorkspace.shared.open(url) }

    // MARK: usage

    /// Counts one use (a translation shown, something read aloud) and, at a quiet moment
    /// afterwards, maybe asks.
    static func used() {
        d.set(d.integer(forKey: "support.uses") + 1, forKey: "support.uses")
        let today = Int(Date().timeIntervalSince1970 / 86_400)
        if d.integer(forKey: "support.lastDay") != today {
            d.set(today, forKey: "support.lastDay")
            d.set(d.integer(forKey: "support.days") + 1, forKey: "support.days")
        }
        if d.object(forKey: "support.firstUse") == nil { d.set(Date(), forKey: "support.firstUse") }
    }

    static func maybeAsk() {
        guard panel == nil, d.integer(forKey: "support.uses") >= 30, d.integer(forKey: "support.days") >= 5 else { return }
        if let until = d.object(forKey: "support.quietUntil") as? Date, until > Date() { return }
        if let first = d.object(forKey: "support.firstUse") as? Date, Date().timeIntervalSince(first) < 14 * 86_400 { return }
        // Not again for a month unless they choose otherwise.
        d.set(Date().addingTimeInterval(30 * 86_400), forKey: "support.quietUntil")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            card(title: "Enjoying Lingveil?",
                 text: "It's free and made by one person. If it helps you read the web or your apps, a coffee on Ko-fi keeps it going.",
                 snooze: true)
        }
    }

    /// After an update: what changed is in the release notes; one line about supporting it.
    static func debugShow() {
        card(title: "Enjoying Lingveil?", text: "It's free and made by one person. If it helps you read the web or your apps, a coffee on Ko-fi keeps it going.", snooze: true)
    }

    static func noteUpdate() {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let last = d.string(forKey: "support.lastVersion")
        d.set(v, forKey: "support.lastVersion")
        guard let last, last != v else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            card(title: "Lingveil was updated to \(v)", text: "Thanks for using it. If it's useful to you, you can support it on Ko-fi.", snooze: false)
        }
    }

    // MARK: UI

    /// A small card in the bottom-right corner; it never takes focus or blocks anything.
    private static func card(title: String, text: String, snooze: Bool) {
        panel?.orderOut(nil)
        let heart = NSImageView(image: NSImage(systemSymbolName: "heart.fill", accessibilityDescription: nil)!)
        heart.contentTintColor = NSColor(red: 1, green: 0.37, blue: 0.36, alpha: 1)
        heart.symbolConfiguration = .init(pointSize: 18, weight: .semibold)
        let t = NSTextField(labelWithString: title); t.font = .systemFont(ofSize: 13, weight: .semibold)
        let body = NSTextField(wrappingLabelWithString: text); body.font = .systemFont(ofSize: 12); body.textColor = .secondaryLabelColor
        body.preferredMaxLayoutWidth = 270
        let support = NSButton(title: "Support on Ko-fi", target: SupportActions.shared, action: #selector(SupportActions.support))
        support.bezelStyle = .push; support.keyEquivalent = ""
        support.contentTintColor = .white
        support.bezelColor = NSColor(red: 1, green: 0.37, blue: 0.36, alpha: 1)
        let later = NSButton(title: snooze ? "Not Now" : "Close", target: SupportActions.shared, action: #selector(SupportActions.close))
        later.bezelStyle = .push
        var buttons: [NSView] = [support, later]
        if snooze {
            let quiet = NSButton(title: "Don't show for 2 months", target: SupportActions.shared, action: #selector(SupportActions.pause))
            quiet.isBordered = false; quiet.contentTintColor = .secondaryLabelColor; quiet.font = .systemFont(ofSize: 11)
            buttons.append(quiet)
        }
        let row = NSStackView(views: buttons); row.spacing = 8
        let textCol = NSStackView(views: [t, body, row]); textCol.orientation = .vertical; textCol.alignment = .leading; textCol.spacing = 6
        let all = NSStackView(views: [heart, textCol]); all.alignment = .top; all.spacing = 12
        all.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 18, right: 16)
        let fx = NSVisualEffectView(); fx.material = .popover; fx.state = .active
        fx.maskImage = NSImage(size: CGSize(width: 25, height: 25), flipped: false) { r in
            NSColor.black.setFill(); NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12).fill(); return true
        }
        fx.maskImage?.capInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        fx.maskImage?.resizingMode = .stretch
        fx.addSubview(all)
        all.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([all.leadingAnchor.constraint(equalTo: fx.leadingAnchor), all.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
                                     all.topAnchor.constraint(equalTo: fx.topAnchor), all.bottomAnchor.constraint(equalTo: fx.bottomAnchor)])
        var size = all.fittingSize
        size.height += 4
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let p = NSPanel(contentRect: CGRect(x: screen.maxX - size.width - 16, y: screen.minY + 16, width: size.width, height: size.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = fx
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.25; p.animator().alphaValue = 1 }
        panel = p
    }

    static func pauseTwoMonths() { d.set(Date().addingTimeInterval(60 * 86_400), forKey: "support.quietUntil"); dismissCard() }
    static func dismissCard() {
        guard let p = panel else { return }
        panel = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; p.animator().alphaValue = 0 }) { p.orderOut(nil) }
    }

    /// "♥ Donate" for a window's title bar, right corner (as in Earmark).
    static func titlebarButton() -> NSTitlebarAccessoryViewController {
        let button = NSButton(title: " Donate", image: NSImage(systemSymbolName: "heart.fill", accessibilityDescription: nil)!,
                              target: SupportActions.shared, action: #selector(SupportActions.open))
        button.isBordered = false
        button.imagePosition = .imageLeading
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.contentTintColor = NSColor(red: 1, green: 0.37, blue: 0.36, alpha: 1)
        button.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        button.toolTip = "Support Lingveil on Ko-fi"
        button.sizeToFit()
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: button.frame.width + 14, height: 28))
        button.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(button)
        NSLayoutConstraint.activate([button.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
                                     button.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -12)])
        let vc = NSTitlebarAccessoryViewController()
        vc.view = holder
        vc.layoutAttribute = .trailing
        return vc
    }


    /// Credits for the About panel.
    static var credits: NSAttributedString {
        let s = NSMutableAttributedString(string: "Free and open source. If it helps you, ",
                                          attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        s.append(NSAttributedString(string: "buy me a coffee on Ko-fi", attributes: [.font: NSFont.systemFont(ofSize: 11), .link: url]))
        s.append(NSAttributedString(string: ".", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        let c = NSMutableParagraphStyle(); c.alignment = .center
        s.addAttribute(.paragraphStyle, value: c, range: NSRange(location: 0, length: s.length))
        return s
    }
}

/// Target for the buttons above (selectors need an Objective-C object).
@MainActor
final class SupportActions: NSObject {
    static let shared = SupportActions()
    @objc func support() { Support.open(); Support.dismissCard() }
    @objc func close() { Support.dismissCard() }
    @objc func pause() { Support.pauseTwoMonths() }
    @objc func open() { Support.open() }
}
