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
        if let snapshot = entry.snapshot, snapshot.accounts.contains(where: { $0.hasNumbers }) {
            if snapshot.accounts.count > 1 {
                if family == .systemSmall {
                    smallBoth(snapshot)
                } else {
                    mediumBoth(snapshot)
                }
            } else if let account = snapshot.accounts.first {
                single(account)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Claude usage")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                Text(entry.snapshot?.accounts.compactMap { $0.message }.first
                     ?? "Open Leeway and sign in to see your limits here.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // MARK: One account

    private func single(_ account: WidgetSnapshot.Account) -> some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 8 : 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Claude usage")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 4)
                if family != .systemSmall && !account.subtitle.isEmpty {
                    Text(account.subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            if let session = account.session {
                LimitView(label: "Session", limit: session, date: entry.date, compact: family == .systemSmall)
            }
            if let weekly = account.weekly {
                LimitView(label: "Weekly", limit: weekly, date: entry.date, compact: family == .systemSmall)
            }
            Spacer(minLength: 0)
            footer(message: account.message, updated: account.updated)
        }
    }

    // MARK: Two accounts

    /// Each account in its own column, with both limits and their reset times.
    private func mediumBoth(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(Array(snapshot.accounts.enumerated()), id: \.offset) { index, account in
                    if index > 0 { Divider() }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(account.name)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        if account.hasNumbers {
                            if let session = account.session {
                                LimitView(label: "Session", limit: session, date: entry.date, compact: true)
                            }
                            if let weekly = account.weekly {
                                LimitView(label: "Weekly", limit: weekly, date: entry.date, compact: true)
                            }
                        } else {
                            notConnected(account)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            Spacer(minLength: 0)
            footer(message: firstProblem(snapshot), updated: snapshot.latestUpdate)
        }
    }

    /// Both accounts stacked, one short bar per limit.
    private func smallBoth(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(snapshot.accounts.enumerated()), id: \.offset) { _, account in
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    if account.hasNumbers {
                        MiniLimitRow(label: "Session", limit: account.session, date: entry.date)
                        MiniLimitRow(label: "Weekly", limit: account.weekly, date: entry.date)
                    } else {
                        notConnected(account)
                    }
                }
            }
            Spacer(minLength: 0)
            footer(message: firstProblem(snapshot), updated: snapshot.latestUpdate)
        }
    }

    private func notConnected(_ account: WidgetSnapshot.Account) -> some View {
        Text(account.message ?? "Not signed in yet. Open Leeway's Settings.")
            .font(.system(size: 9))
            .foregroundColor(.secondary)
            .lineLimit(3)
    }

    /// The first account whose last refresh failed although it has numbers to show.
    private func firstProblem(_ snapshot: WidgetSnapshot) -> String? {
        guard let account = snapshot.accounts.first(where: { $0.hasNumbers && $0.message != nil }),
              let message = account.message else { return nil }
        return "\(account.name): \(message)"
    }

    @ViewBuilder private func footer(message: String?, updated: Date?) -> some View {
        if let message = message {
            Text(message)
                .font(.system(size: 9))
                .foregroundColor(.orange)
                .lineLimit(family == .systemSmall ? 1 : 2)
        } else if let updated = updated {
            Text("Updated " + WidgetTime.when(updated, now: entry.date))
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }
}

/// One limit in a single line: name, a short bar and the percent.
struct MiniLimitRow: View {
    let label: String
    let limit: WidgetSnapshot.Limit?
    let date: Date

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .frame(width: 42, alignment: .leading)
            UsageBarView(value: limit?.used ?? 0, marker: limit?.elapsedFraction(at: date))
                .frame(height: 4)
            Text(limit.map { "\(Int($0.used.rounded()))%" } ?? "--")
                .font(Font.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundColor(limit.map { WidgetColors.text($0.used) } ?? .secondary)
                .frame(width: 30, alignment: .trailing)
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
            return compact ? "Starts on next use" : "Starts when you next use Claude"
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
    /// Desktop widgets (macOS 14 and later) need a container background.
    func widgetBackground() -> some View {
        containerBackground(.fill.tertiary, for: .widget)
    }
}
