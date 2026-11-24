import AppKit

enum StatusRenderer {
    private static var cachedIcon: NSImage?

    /// What the menu bar shows for one account. `label` is the account's initial,
    /// set when more than one account is shown.
    struct Item {
        let label: String?
        let name: String?
        let session: UsageWindow?
        let weekly: UsageWindow?
        let hasError: Bool
    }

    static func render(button: NSStatusBarButton, items: [Item], settings: AppSettings, now: Date) {
        button.toolTip = tooltip(items: items, now: now)

        if settings.barStyle == .miniBars {
            button.attributedTitle = NSAttributedString(string: "")
            button.image = miniBarsImage(items: items, colored: settings.colorWhenHigh)
            button.imagePosition = .imageOnly
            return
        }

        let icon = settings.showIcon ? gaugeIcon() : nil
        button.image = icon
        button.imagePosition = icon == nil ? .noImage : .imageLeading
        let output = NSMutableAttributedString()
        for (index, item) in items.enumerated() {
            if index > 0 {
                output.append(NSAttributedString(string: "   ", attributes: [.font: NSFont.systemFont(ofSize: 12)]))
            }
            output.append(title(style: settings.barStyle, item: item,
                                colored: settings.colorWhenHigh, leadingSpace: index == 0 && icon != nil, now: now))
        }
        button.attributedTitle = output
    }

    static func alertColor(_ used: Double) -> NSColor? {
        if used >= 90 { return .systemRed }
        if used >= 75 { return .systemOrange }
        return nil
    }

    private static func title(style: BarStyle, item: Item,
                              colored: Bool, leadingSpace: Bool, now: Date) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let output = NSMutableAttributedString()
        let session = item.session
        let weekly = item.weekly

        func add(_ text: String, used: Double? = nil, quiet: Bool = false, bold: Bool = false) {
            var attributes: [NSAttributedString.Key: Any] = [.font: bold ? NSFont.systemFont(ofSize: 11, weight: .bold) : font]
            if quiet {
                attributes[.foregroundColor] = NSColor.secondaryLabelColor
            } else if colored, let used = used, let color = alertColor(used) {
                attributes[.foregroundColor] = color
            }
            output.append(NSAttributedString(string: text, attributes: attributes))
        }

        func value(_ window: UsageWindow?, left: Bool) -> (text: String, used: Double?) {
            guard let window = window else { return ("--", nil) }
            return (TextFormat.percent(left ? window.left : window.used), window.used)
        }

        if leadingSpace { add(" ") }
        if let label = item.label { add(label + " ", quiet: true, bold: true) }

        switch style {
        case .bothUsed, .bothLeft:
            let showLeft = style == .bothLeft
            let first = value(session, left: showLeft)
            let second = value(weekly, left: showLeft)
            add(first.text, used: first.used)
            add(" | ", quiet: true)
            add(second.text, used: second.used)
            if showLeft { add(" left", quiet: true) }
        case .sessionReset:
            let first = value(session, left: false)
            add(first.text, used: first.used)
            if let reset = session?.resetsAt, reset > now {
                add(" ↻ " + TextFormat.countdown(to: reset, now: now), quiet: true)
            }
        case .sessionOnly:
            let first = value(session, left: false)
            add(first.text, used: first.used)
        case .miniBars:
            break
        }
        return output
    }

    private static func gaugeIcon() -> NSImage? {
        if let icon = cachedIcon { return icon }
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        for name in ["gauge.with.dots.needle.33percent", "gauge", "speedometer"] {
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: "Claude usage")?
                .withSymbolConfiguration(config) {
                image.isTemplate = true
                cachedIcon = image
                return image
            }
        }
        return nil
    }

    /// Two bars per account (session on top, week below), with the account's initial
    /// in front when more than one account is shown.
    private static func miniBarsImage(items: [Item], colored: Bool) -> NSImage {
        let values = items.map { (label: $0.label, session: $0.session?.used ?? 0, weekly: $0.weekly?.used ?? 0) }
        let useColor = colored && values.contains { alertColor($0.session) != nil || alertColor($0.weekly) != nil }
        let barWidth: CGFloat = 26
        let labelWidth: CGFloat = 9
        let gap: CGFloat = 6
        let blockWidths = values.map { ($0.label == nil ? 0 : labelWidth) + barWidth }
        let width = blockWidths.reduce(0, +) + gap * CGFloat(max(values.count - 1, 0)) + 2
        let font = NSFont.systemFont(ofSize: 9, weight: .bold)
        let image = NSImage(size: NSSize(width: max(width, 28), height: 16), flipped: false) { _ in
            var x: CGFloat = 1
            for value in values {
                if let label = value.label {
                    let ink: NSColor = useColor ? .labelColor : .black
                    let text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: ink])
                    let size = text.size()
                    text.draw(at: NSPoint(x: x + (labelWidth - 2 - size.width) / 2, y: (16 - size.height) / 2))
                    x += labelWidth
                }
                drawBar(in: NSRect(x: x, y: 9, width: barWidth, height: 5), value: value.session, colored: useColor)
                drawBar(in: NSRect(x: x, y: 2, width: barWidth, height: 5), value: value.weekly, colored: useColor)
                x += barWidth + gap
            }
            return true
        }
        // Template images follow the menu bar's light or dark look automatically.
        image.isTemplate = !useColor
        image.accessibilityDescription = items.map { item in
            let prefix = item.name.map { "\($0): " } ?? ""
            return prefix + "session \(TextFormat.percent(item.session?.used ?? 0)), weekly \(TextFormat.percent(item.weekly?.used ?? 0))"
        }.joined(separator: "; ")
        return image
    }

    private static func drawBar(in rect: NSRect, value: Double, colored: Bool) {
        let radius = rect.height / 2
        let ink: NSColor = colored ? .labelColor : .black
        ink.withAlphaComponent(0.28).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()

        let fraction = CGFloat(min(max(value, 0), 100) / 100)
        guard fraction > 0 else { return }
        var filled = rect
        filled.size.width = max(rect.height, rect.width * fraction)
        let fill: NSColor = colored ? (alertColor(value) ?? .labelColor) : .black
        fill.setFill()
        NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
    }

    private static func tooltip(items: [Item], now: Date) -> String {
        var lines: [String] = []
        for item in items {
            let prefix = item.name.map { "\($0) - " } ?? ""
            var added = false
            if let session = item.session {
                lines.append("\(prefix)Session \(TextFormat.percent(session.used)) used. \(TextFormat.resetSentence(session.resetsAt, now: now))")
                added = true
            }
            if let weekly = item.weekly {
                lines.append("\(prefix)Weekly \(TextFormat.percent(weekly.used)) used. \(TextFormat.resetSentence(weekly.resetsAt, now: now))")
                added = true
            }
            if !added { lines.append("\(prefix)Not connected yet") }
            if item.hasError { lines.append("\(prefix)The last refresh failed. Click for details.") }
        }
        if lines.isEmpty { lines.append("Leeway: not connected yet") }
        return lines.joined(separator: "\n")
    }
}
