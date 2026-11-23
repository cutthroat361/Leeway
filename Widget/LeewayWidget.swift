import SwiftUI
import WidgetKit

// Leeway's widget: the current session and weekly limit, read from the summary
// the Leeway app saves after each refresh. Clicking the widget opens Leeway.

@main
struct LeewayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LeewayUsage", provider: UsageProvider()) { entry in
            UsageWidgetView(entry: entry)
        }
        .configurationDisplayName("Claude usage")
        .description("Your current session and weekly limit, from Leeway.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: Timeline

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: Date(), snapshot: WidgetSnapshot.sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        var snapshot = WidgetSnapshot.load()
        if snapshot == nil && context.isPreview { snapshot = WidgetSnapshot.sample }
        completion(UsageEntry(date: Date(), snapshot: snapshot))
    }

    /// One entry every 15 minutes for two hours, so the pace ticks keep moving.
    /// Leeway also asks for a fresh timeline after every refresh.
    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let snapshot = WidgetSnapshot.load()
        let now = Date()
        let entries = (0..<8).map { step in
            UsageEntry(date: now.addingTimeInterval(Double(step) * 15 * 60), snapshot: snapshot)
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(2 * 60 * 60))))
    }
}

// MARK: Views

struct UsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageEntry

    var body: some View {
        content
            .widgetURL(URL(string: "leeway://open"))
            .widgetBackground()
    }

    @ViewBuilder private var content: some View {
        if let snapshot = entry.snapshot, snapshot.session != nil || snapshot.weekly != nil {
            VStack(alignment: .leading, spacing: family == .systemSmall ? 8 : 10) {
                header(snapshot)
                if let session = snapshot.session {
                    LimitView(label: "Session", limit: session, date: entry.date, compact: family == .systemSmall)
                }
                if let weekly = snapshot.weekly {
                    LimitView(label: "Weekly", limit: weekly, date: entry.date, compact: family == .systemSmall)
                }
                Spacer(minLength: 0)
                footer(snapshot)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Claude usage")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                Text(entry.snapshot?.message ?? "Open Leeway and sign in to see your limits here.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func header(_ snapshot: WidgetSnapshot) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Claude usage")
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 4)
            if family != .systemSmall && !snapshot.subtitle.isEmpty {
                Text(snapshot.subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder private func footer(_ snapshot: WidgetSnapshot) -> some View {
        if let message = snapshot.message {
            Text(message)
                .font(.system(size: 9))
                .foregroundColor(.orange)
                .lineLimit(2)
        } else if let updated = snapshot.updated {
            (Text("Updated ") + Text(updated, style: .relative) + Text(" ago"))
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }
}

struct LimitView: View {
    let label: String
    let limit: WidgetSnapshot.Limit
    let date: Date
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 4)
                Text("\(Int(limit.used.rounded()))%")
                    .font(Font.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundColor(WidgetColors.text(limit.used))
            }
            UsageBarView(value: limit.used, marker: limit.elapsedFraction(at: date))
                .frame(height: compact ? 5 : 6)
            HStack(alignment: .firstTextBaseline) {
                Text(resetText)
                    .lineLimit(1)
                if !compact, let pace = limit.paceText {
                    Spacer(minLength: 4)
                    Text(pace)
                        .foregroundColor(WidgetColors.pace(limit.paceLevel))
                        .lineLimit(1)
                }
            }
            .font(.system(size: compact ? 9 : 10))
            .foregroundColor(.secondary)
        }
    }

    private var resetText: String {
        guard let reset = limit.resetsAt, reset > date else {
            return "Starts when you next use Claude"
        }
        return "Resets " + WidgetTime.when(reset, now: date)
    }
}

struct UsageBarView: View {
    let value: Double
    let marker: Double?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.25))
                Capsule()
                    .fill(WidgetColors.bar(value))
                    .frame(width: max(CGFloat(min(max(value, 0), 100) / 100) * geometry.size.width,
                                      value > 0 ? geometry.size.height : 0))
                if let marker = marker {
                    Rectangle()
                        .fill(Color.primary.opacity(0.6))
                        .frame(width: 1.5, height: geometry.size.height + 4)
                        .offset(x: CGFloat(marker) * geometry.size.width - 0.75)
                }
            }
        }
    }
}

// MARK: Helpers

enum WidgetColors {
    static func bar(_ used: Double) -> Color {
        if used >= 90 { return .red }
        if used >= 75 { return .orange }
        return .accentColor
    }

    static func text(_ used: Double) -> Color {
        if used >= 90 { return .red }
        if used >= 75 { return .orange }
        return .primary
    }

    static func pace(_ level: String?) -> Color {
        switch level ?? "" {
        case "atLimit", "runningOut": return .red
        case "tight": return .orange
        default: return .secondary
        }
    }
}

enum WidgetTime {
    /// "9:10 PM" or "21:10" today, "Sun 11:00 AM" within the week, "Nov 28" further out,
    /// following the Mac's 12/24-hour setting like the menu bar does.
    static func when(_ date: Date, now: Date) -> String {
        let time = DateFormatter()
        time.dateStyle = .none
        time.timeStyle = .short
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "AppleICUForce24HourTime") {
            time.setLocalizedDateFormatFromTemplate("HHmm")
        } else if defaults.bool(forKey: "AppleICUForce12HourTime") {
            time.setLocalizedDateFormatFromTemplate("hmma")
        }
        if Calendar.current.isDate(date, inSameDayAs: now) {
            return time.string(from: date)
        }
        let day = DateFormatter()
        if date.timeIntervalSince(now) < 6 * 86400 {
            day.setLocalizedDateFormatFromTemplate("EEE")
            return day.string(from: date) + " " + time.string(from: date)
        }
        day.setLocalizedDateFormatFromTemplate("MMMd")
        return day.string(from: date)
    }
}

extension View {
    /// macOS 14 and later draw widgets on the desktop and need a container background;
    /// older versions show them in Notification Center and need padding instead.
    @ViewBuilder func widgetBackground() -> some View {
        if #available(macOS 14.0, *) {
            containerBackground(.fill.tertiary, for: .widget)
        } else {
            padding(14)
        }
    }
}
