import Foundation

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
}

/// One usage limit, for example the 5-hour session or the weekly limit.
struct UsageWindow: Identifiable, Equatable {
    let id: String
    let title: String
    /// Percent used, 0 to 100.
    let utilization: Double
    let resetsAt: Date?
    /// Length of the window in seconds (5 hours, 7 days), when known.
    let length: TimeInterval?

    var used: Double { max(0, utilization) }
    var left: Double { max(0, 100 - utilization) }

    /// How much of the window has passed, from 0 to 1.
    func elapsedFraction(now: Date = Date()) -> Double? {
        guard let reset = resetsAt, let length = length, length > 0, reset > now else { return nil }
        let start = reset.addingTimeInterval(-length)
        return min(max(now.timeIntervalSince(start) / length, 0), 1)
    }

    /// Projects usage forward at the current rate.
    func pace(now: Date = Date()) -> Pace? {
        guard let reset = resetsAt, let length = length, length > 0, reset > now else { return nil }
        let start = reset.addingTimeInterval(-length)
        let elapsed = min(now.timeIntervalSince(start), length)
        guard elapsed > length * 0.05 else { return nil }
        let fraction = elapsed / length

        if utilization >= 100 {
            return Pace(level: .atLimit, projected: utilization, limitDate: nil, elapsedFraction: fraction)
        }
        if utilization <= 0 {
            return Pace(level: .relaxed, projected: 0, limitDate: nil, elapsedFraction: fraction)
        }

        let projected = utilization * length / elapsed
        var limitDate: Date? = nil
        if projected > 100 {
            let percentPerSecond = utilization / elapsed
            limitDate = now.addingTimeInterval((100 - utilization) / percentPerSecond)
        }

        let level: Pace.Level
        if projected > 100 {
            level = .runningOut
        } else if projected > 85 {
            level = .tight
        } else if projected > 50 {
            level = .steady
        } else {
            level = .relaxed
        }
        return Pace(level: level, projected: projected, limitDate: limitDate, elapsedFraction: fraction)
    }
}

struct Pace {
    enum Level {
        case relaxed
        case steady
        case tight
        case runningOut
        case atLimit
    }

    let level: Level
    /// Percent you would reach by the reset if you keep going at this rate.
    let projected: Double
    /// When you would hit 100%, if that happens before the reset.
    let limitDate: Date?
    let elapsedFraction: Double
}

/// Reads the usage JSON from claude.ai or Anthropic. Written to be forgiving,
/// because the endpoint is unofficial and its shape changes now and then.
enum UsageParser {
    static let utilizationKeys = ["utilization", "utilization_pct", "percent_used", "used_percent"]
    static let resetKeys = ["resets_at", "reset_at", "resetsAt", "reset_time"]

    static func parse(_ data: Data) throws -> [UsageWindow] {
        guard let root = try? JSONSerialization.jsonObject(with: data),
              let dict = root as? [String: Any] else {
            throw UsageError.badResponse("The usage data came back in a format Leeway doesn't understand.")
        }

        var windows: [UsageWindow] = []
        for (key, value) in dict {
            if key.hasPrefix("extra") { continue }
            guard let item = value as? [String: Any],
                  let utilization = number(item, utilizationKeys) else { continue }
            windows.append(UsageWindow(id: key,
                                       title: title(for: key),
                                       utilization: utilization,
                                       resetsAt: date(item, resetKeys),
                                       length: length(for: key)))
        }

        // Newer responses can also carry a "limits" list.
        if let limits = dict["limits"] as? [[String: Any]] {
            for (index, item) in limits.enumerated() {
                guard let utilization = number(item, utilizationKeys) else { continue }
                let limitId = string(item, ["id", "key", "type", "window", "name"]) ?? "limit_\(index)"
                if windows.contains(where: { $0.id == limitId }) { continue }
                let displayTitle = string(item, ["display_name", "label", "title"]) ?? title(for: limitId)
                let windowLength = number(item, ["window_seconds", "duration_seconds"]) ?? length(for: limitId)
                windows.append(UsageWindow(id: limitId,
                                           title: displayTitle,
                                           utilization: utilization,
                                           resetsAt: date(item, resetKeys),
                                           length: windowLength))
            }
        }

        guard !windows.isEmpty else {
            throw UsageError.badResponse("No usage limits were found for this account.")
        }
        return windows.sorted { a, b in
            let rankA = rank(a.id)
            let rankB = rank(b.id)
            return rankA != rankB ? rankA < rankB : a.title < b.title
        }
    }

    static func rank(_ id: String) -> Int {
        if id == "five_hour" { return 0 }
        if id == "seven_day" { return 1 }
        if id.contains("five_hour") || id.contains("session") { return 2 }
        if id.contains("seven_day") || id.contains("week") { return 3 }
        return 4
    }

    static func title(for key: String) -> String {
        if key == "five_hour" { return "Current session" }
        if key == "seven_day" { return "Weekly, all models" }
        if key.hasPrefix("seven_day_") {
            return "Weekly, " + prettify(String(key.dropFirst("seven_day_".count)))
        }
        return prettify(key)
    }

    static func prettify(_ key: String) -> String {
        let known = ["opus": "Opus", "sonnet": "Sonnet", "haiku": "Haiku", "fable": "Fable",
                     "mythos": "Mythos", "oauth": "OAuth", "design": "Design"]
        let words = key.split(separator: "_").map { word -> String in
            let lower = word.lowercased()
            return known[lower] ?? lower
        }
        let joined = words.joined(separator: " ")
        guard let first = joined.first else { return key }
        return String(first).uppercased() + String(joined.dropFirst())
    }

    static func length(for key: String) -> TimeInterval? {
        if key.contains("five_hour") || key.contains("session") { return 5 * 3600 }
        if key.contains("seven_day") || key.contains("week") { return 7 * 86400 }
        if key.contains("day") { return 86400 }
        return nil
    }

    static func number(_ item: [String: Any], _ keys: [String]) -> Double? {
        for key in keys {
            if let value = item[key] as? NSNumber { return value.doubleValue }
            if let value = item[key] as? String, let parsed = Double(value) { return parsed }
        }
        return nil
    }

    static func string(_ item: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let value = item[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    static func date(_ item: [String: Any], _ keys: [String]) -> Date? {
        for key in keys {
            if let value = item[key] as? String, let parsed = parseDate(value) { return roundedToMinute(parsed) }
            if let value = item[key] as? NSNumber {
                let seconds = value.doubleValue
                return roundedToMinute(Date(timeIntervalSince1970: seconds > 1e12 ? seconds / 1000 : seconds))
            }
        }
        return nil
    }

    /// Reset times arrive to the second and drift a little between refreshes
    /// (19:59:59 one time, 20:00:01 the next). Round so they read like claude.ai.
    static func roundedToMinute(_ date: Date) -> Date {
        let seconds = date.timeIntervalSince1970
        return Date(timeIntervalSince1970: (seconds / 60).rounded() * 60)
    }

    static func parseDate(_ raw: String) -> Date? {
        // Parse without fractional seconds (older macOS versions choke on 6 digits),
        // then add them back so rounding to the minute goes the right way.
        var fraction = 0.0
        if let range = raw.range(of: "\\.[0-9]+", options: .regularExpression) {
            fraction = Double("0" + String(raw[range])) ?? 0
        }
        let cleaned = raw.replacingOccurrences(of: "\\.[0-9]+", with: "", options: .regularExpression)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: cleaned)?.addingTimeInterval(fraction)
    }
}

enum TextFormat {
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter
    }()

    private static let dayTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEjmm")
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    static func percent(_ value: Double) -> String {
        return "\(Int(value.rounded()))%"
    }

    /// "8:00 PM" today, "Sun 11:00 AM" within the week, "Nov 28" further out.
    static func when(_ date: Date, now: Date = Date()) -> String {
        if Calendar.current.isDate(date, inSameDayAs: now) {
            return timeFormatter.string(from: date)
        }
        if abs(date.timeIntervalSince(now)) < 6 * 86400 {
            return dayTimeFormatter.string(from: date)
        }
        return dayFormatter.string(from: date)
    }

    /// Matches the wording on the claude.ai usage page.
    static func resetLine(_ date: Date?, now: Date = Date()) -> String {
        guard let date = date, date > now else { return "Starts when you next use Claude" }
        let prefix = Calendar.current.isDate(date, inSameDayAs: now) ? "Resets at " : "Resets "
        return prefix + when(date, now: now)
    }

    static func resetSentence(_ date: Date?, now: Date = Date()) -> String {
        guard let date = date, date > now else { return "It resets once the current window ends." }
        return "\(resetLine(date, now: now)), in \(countdown(to: date, now: now))."
    }

    static func countdown(to date: Date?, now: Date = Date()) -> String {
        guard let date = date else { return "" }
        let seconds = Int(date.timeIntervalSince(now))
        if seconds <= 0 { return "now" }
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "<1m"
    }

    static func updatedAgo(_ date: Date?, now: Date = Date()) -> String {
        guard let date = date else { return "Not updated yet" }
        if now.timeIntervalSince(date) < 45 { return "Updated just now" }
        return "Updated " + relativeFormatter.localizedString(for: date, relativeTo: now)
    }
}
