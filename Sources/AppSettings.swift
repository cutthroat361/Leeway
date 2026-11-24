import Foundation
import Combine

/// The three ways Leeway can read your usage.
enum AuthMethod: String, CaseIterable, Identifiable {
    case claudeCode
    case browser
    case sessionKey

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claudeCode: return "Use my Claude Code login"
        case .browser: return "Sign in with a claude.ai window"
        case .sessionKey: return "Paste a session key"
        }
    }

    /// Both web methods end up with a claude.ai session key.
    var usesWebSession: Bool { self != .claudeCode }
}

/// What the menu bar item shows.
enum BarStyle: String, CaseIterable, Identifiable {
    case bothUsed
    case bothLeft
    case miniBars
    case sessionReset
    case sessionOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bothUsed: return "Session and weekly used"
        case .bothLeft: return "Session and weekly left"
        case .miniBars: return "Two mini bars"
        case .sessionReset: return "Session and time until it resets"
        case .sessionOnly: return "Session only"
        }
    }

    var example: String {
        switch self {
        case .bothUsed: return "12% | 48%"
        case .bothLeft: return "88% | 52% left"
        case .miniBars: return "top bar is the session, bottom bar is the week"
        case .sessionReset: return "12% ↻ 3h 49m"
        case .sessionOnly: return "12%"
        }
    }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    static let refreshChoices = [1, 2, 5, 10, 15, 30]

    /// Every Claude account Leeway watches, in the order they're shown.
    @Published var accounts: [Account] { didSet { saveAccounts() } }
    /// What the menu bar and popover show: `DisplayChoice.both` or one account's id.
    @Published var display: String { didSet { store(display, "display") } }
    /// What the desktop widget shows: `DisplayChoice.both` or one account's id.
    @Published var widgetShows: String { didSet { store(widgetShows, "widgetShows") } }
    @Published var barStyle: BarStyle { didSet { store(barStyle.rawValue, "barStyle") } }
    @Published var showIcon: Bool { didSet { store(showIcon, "showIcon") } }
    @Published var colorWhenHigh: Bool { didSet { store(colorWhenHigh, "colorWhenHigh") } }
    @Published var refreshMinutes: Int { didSet { store(refreshMinutes, "refreshMinutes") } }
    @Published var alertsEnabled: Bool { didSet { store(alertsEnabled, "alertsEnabled") } }
    @Published var alertAt75: Bool { didSet { store(alertAt75, "alertAt75") } }
    @Published var alertAt90: Bool { didSet { store(alertAt90, "alertAt90") } }
    @Published var alertAtLimit: Bool { didSet { store(alertAtLimit, "alertAtLimit") } }
    @Published var paceWarning: Bool { didSet { store(paceWarning, "paceWarning") } }
    @Published var notifyOnReset: Bool { didSet { store(notifyOnReset, "notifyOnReset") } }
    @Published var hasCompletedSetup: Bool { didSet { store(hasCompletedSetup, "hasCompletedSetup") } }
    @Published var checkForUpdates: Bool { didSet { store(checkForUpdates, "checkForUpdates") } }
    @Published var showInMenuBar: Bool { didSet { store(showInMenuBar, "showInMenuBar") } }

    private init() {
        let defaults = UserDefaults.standard
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key) as? Bool ?? fallback
        }
        func text(_ key: String) -> String {
            defaults.string(forKey: key) ?? ""
        }

        accounts = AppSettings.loadAccounts(defaults)
        display = text("display").isEmpty ? DisplayChoice.both : text("display")
        widgetShows = text("widgetShows").isEmpty ? DisplayChoice.both : text("widgetShows")
        barStyle = BarStyle(rawValue: text("barStyle")) ?? .bothUsed
        showIcon = bool("showIcon", true)
        colorWhenHigh = bool("colorWhenHigh", true)
        let minutes = defaults.integer(forKey: "refreshMinutes")
        refreshMinutes = AppSettings.refreshChoices.contains(minutes) ? minutes : 5
        alertsEnabled = bool("alertsEnabled", true)
        alertAt75 = bool("alertAt75", true)
        alertAt90 = bool("alertAt90", true)
        alertAtLimit = bool("alertAtLimit", true)
        paceWarning = bool("paceWarning", true)
        notifyOnReset = bool("notifyOnReset", true)
        hasCompletedSetup = bool("hasCompletedSetup", false)
        checkForUpdates = bool("checkForUpdates", true)
        showInMenuBar = bool("showInMenuBar", true)
    }

    private func store(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    // MARK: Accounts

    static let maxAccounts = 2

    func account(_ id: String) -> Account? {
        accounts.first { $0.id == id }
    }

    /// Changes one account in place. Does nothing if the account is gone.
    func updateAccount(_ id: String, _ change: (inout Account) -> Void) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        var account = accounts[index]
        change(&account)
        if account != accounts[index] { accounts[index] = account }
    }

    @discardableResult
    func addAccount() -> Account? {
        guard accounts.count < AppSettings.maxAccounts else { return nil }
        let taken = Set(accounts.map { $0.name.lowercased() })
        let name = ["Work", "Personal"].first { !taken.contains($0.lowercased()) } ?? "Account \(accounts.count + 1)"
        let account = Account(id: UUID().uuidString, name: name, authMethod: .browser)
        accounts.append(account)
        return account
    }

    func removeAccount(_ id: String) {
        guard accounts.count > 1 else { return }
        accounts.removeAll { $0.id == id }
        if display == id { display = DisplayChoice.both }
        if widgetShows == id { widgetShows = DisplayChoice.both }
    }

    /// The accounts the menu bar and popover show right now.
    var displayedAccounts: [Account] {
        DisplayChoice.accounts(for: display, in: accounts)
    }

    private func saveAccounts() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: "accounts")
        }
    }

    /// Reads the saved accounts. Before Leeway 1.4 there was one account, kept in
    /// separate settings; it becomes the first account, with the same sign-in.
    private static func loadAccounts(_ defaults: UserDefaults) -> [Account] {
        if let data = defaults.data(forKey: "accounts"),
           let saved = try? JSONDecoder().decode([Account].self, from: data), !saved.isEmpty {
            return saved
        }
        var first = Account(id: Account.primaryId, name: "Personal",
                            authMethod: AuthMethod(rawValue: defaults.string(forKey: "authMethod") ?? "") ?? .browser)
        first.orgId = defaults.string(forKey: "orgId") ?? ""
        first.orgName = defaults.string(forKey: "orgName") ?? ""
        return [first]
    }
}

/// One Claude account: how Leeway signs in to it and which organization it reads.
struct Account: Codable, Identifiable, Equatable {
    /// The account that existed before Leeway supported several. Its Keychain item
    /// and history file keep their old names, so updating loses nothing.
    static let primaryId = "primary"

    let id: String
    var name: String
    var method: String
    var orgId: String = ""
    var orgName: String = ""

    init(id: String, name: String, authMethod: AuthMethod) {
        self.id = id
        self.name = name
        self.method = authMethod.rawValue
    }

    var authMethod: AuthMethod {
        get { AuthMethod(rawValue: method) ?? .browser }
        set { method = newValue.rawValue }
    }

    /// The name, or a stand-in while the field is empty.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Account" : trimmed
    }

    /// The first letter of the name, for the menu bar.
    var initial: String {
        displayName.first.map { String($0).uppercased() } ?? "?"
    }

    var keychainAccount: String {
        id == Account.primaryId ? "sessionKey" : "sessionKey.\(id)"
    }

    var historyFileName: String {
        id == Account.primaryId ? "history.json" : "history-\(id).json"
    }
}

enum DisplayChoice {
    static let both = "both"

    /// The accounts a choice stands for. A choice naming an account that's gone shows all.
    static func accounts(for choice: String, in accounts: [Account]) -> [Account] {
        if choice != both, let one = accounts.first(where: { $0.id == choice }) { return [one] }
        return accounts
    }
}
