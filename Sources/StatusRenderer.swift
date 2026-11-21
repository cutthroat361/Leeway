import AppKit

enum StatusRenderer {
    private static var cachedIcon: NSImage?

    static func render(button: NSStatusBarButton, session: UsageWindow?, weekly: UsageWindow?,
                       settings: AppSettings, hasError: Bool, now: Date) {
        button.toolTip = tooltip(session: session, weekly: weekly, hasError: hasError, now: now)

        if settings.barStyle == .miniBars {
            button.attributedTitle = NSAttributedString(string: "")
            button.image = miniBarsImage(session: session?.used, weekly: weekly?.used, colored: settings.colorWhenHigh)
            button.imagePosition = .imageOnly
            return
        }

        let icon = settings.showIcon ? gaugeIcon() : nil
        button.image = icon
        button.imagePosition = icon == nil ? .noImage : .imageLeading
        button.attributedTitle = title(style: settings.barStyle, session: session, weekly: weekly,
                                       colored: settings.colorWhenHigh, leadingSpace: icon != nil, now: now)
    }

    static func alertColor(_ used: Double) -> NSColor? {
        if used >= 90 { return .systemRed }
        if used >= 75 { return .systemOrange }
        return nil
    }

    private static func title(style: BarStyle, session: UsageWindow?, weekly: UsageWindow?,
                              colored: Bool, leadingSpace: Bool, now: Date) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let output = NSMutableAttributedString()

        func add(_ text: String, used: Double? = nil, quiet: Bool = false) {
            var attributes: [NSAttributedString.Key: Any] = [.font: font]
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

    private static func miniBarsImage(session: Double?, weekly: Double?, colored: Bool) -> NSImage {
        let sessionValue = session ?? 0
        let weeklyValue = weekly ?? 0
        let useColor = colored && (alertColor(sessionValue) != nil || alertColor(weeklyValue) != nil)
        let image = NSImage(size: NSSize(width: 28, height: 16), flipped: false) { rect in
            drawBar(in: NSRect(x: 1, y: 9, width: rect.width - 2, height: 5), value: sessionValue, colored: useColor)
            drawBar(in: NSRect(x: 1, y: 2, width: rect.width - 2, height: 5), value: weeklyValue, colored: useColor)
            return true
        }
        // Template images follow the menu bar's light or dark look automatically.
        image.isTemplate = !useColor
        image.accessibilityDescription = "Session \(TextFormat.percent(sessionValue)), weekly \(TextFormat.percent(weeklyValue))"
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

    private static func tooltip(session: UsageWindow?, weekly: UsageWindow?, hasError: Bool, now: Date) -> String {
        var lines: [String] = []
        if let session = session {
            lines.append("Session \(TextFormat.percent(session.used)) used. \(TextFormat.resetSentence(session.resetsAt, now: now))")
        }
        if let weekly = weekly {
            lines.append("Weekly \(TextFormat.percent(weekly.used)) used. \(TextFormat.resetSentence(weekly.resetsAt, now: now))")
        }
        if lines.isEmpty { lines.append("Leeway: not connected yet") }
        if hasError { lines.append("The last refresh failed. Click for details.") }
        return lines.joined(separator: "\n")
    }
}
