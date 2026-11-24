import Foundation

/// What Leeway hands to its widget after each refresh. The app writes it as JSON to
/// ~/Library/Application Support/Leeway/widget.json; the widget runs in a sandbox that
/// may read that one folder and nothing else. Compiled into both the app and the widget.
struct WidgetSnapshot: Codable {
    struct Limit: Codable {
        /// Percent used, 0 to 100.
        let used: Double
        let resetsAt: Date?
        /// Length of the limit window in seconds, so the widget can move the pace tick.
        let length: TimeInterval?
        /// "On pace", "Runs out around 7:15 PM" and so on, worked out by the app.
        let paceText: String?
        /// "relaxed", "steady", "tight", "runningOut" or "atLimit".
        let paceLevel: String?

        /// How much of the window has passed at `date`, from 0 to 1.
        func elapsedFraction(at date: Date) -> Double? {
            guard let reset = resetsAt, let length = length, length > 0, reset > date else { return nil }
            let start = reset.addingTimeInterval(-length)
            return min(max(date.timeIntervalSince(start) / length, 0), 1)
        }
    }

    /// One account's numbers.
    struct Account: Codable {
        var name: String
        var session: Limit?
        var weekly: Limit?
        /// When the numbers were last fetched successfully.
        var updated: Date?
        /// Organization or login name.
        var subtitle: String
        /// Set when the last refresh failed, for example after a sign-in expired.
        var message: String?

        var hasNumbers: Bool { session != nil || weekly != nil }
    }

    /// The accounts chosen for the widget in Leeway's Settings, in order.
    var accounts: [Account]

    init(accounts: [Account]) {
        self.accounts = accounts
    }

    private enum CodingKeys: String, CodingKey {
        case accounts
        // The one-account format written before Leeway 1.4.
        case session, weekly, updated, subtitle, message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let accounts = try container.decodeIfPresent([Account].self, forKey: .accounts) {
            self.accounts = accounts
            return
        }
        let single = Account(name: "",
                             session: try container.decodeIfPresent(Limit.self, forKey: .session),
                             weekly: try container.decodeIfPresent(Limit.self, forKey: .weekly),
                             updated: try container.decodeIfPresent(Date.self, forKey: .updated),
                             subtitle: try container.decodeIfPresent(String.self, forKey: .subtitle) ?? "",
                             message: try container.decodeIfPresent(String.self, forKey: .message))
        self.accounts = [single]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accounts, forKey: .accounts)
    }

    /// When any of the accounts was last updated.
    var latestUpdate: Date? {
        accounts.compactMap { $0.updated }.max()
    }

    static let fileName = "widget.json"

    /// The real home folder. Inside the widget's sandbox, NSHomeDirectory() points at the
    /// widget's own container instead.
    static var realHome: URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    static var fileURL: URL {
        realHome.appendingPathComponent("Library/Application Support/Leeway/\(fileName)")
    }

    static func load() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    /// Shown in the widget gallery before Leeway has any numbers.
    static var sample: WidgetSnapshot {
        let now = Date()
        return WidgetSnapshot(accounts: [Account(
            name: "",
            session: Limit(used: 42, resetsAt: now.addingTimeInterval(2.5 * 3600), length: 5 * 3600,
                           paceText: "On pace", paceLevel: "steady"),
            weekly: Limit(used: 28, resetsAt: now.addingTimeInterval(4 * 86400), length: 7 * 86400,
                          paceText: "Plenty left", paceLevel: "relaxed"),
            updated: now,
            subtitle: "",
            message: nil)])
    }
}
