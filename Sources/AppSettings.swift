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

    @Published var authMethod: AuthMethod { didSet { store(authMethod.rawValue, "authMethod") } }
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
    @Published var orgId: String { didSet { store(orgId, "orgId") } }
    @Published var orgName: String { didSet { store(orgName, "orgName") } }
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

        authMethod = AuthMethod(rawValue: text("authMethod")) ?? .browser
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
        orgId = text("orgId")
        orgName = text("orgName")
        hasCompletedSetup = bool("hasCompletedSetup", false)
        checkForUpdates = bool("checkForUpdates", true)
        showInMenuBar = bool("showInMenuBar", true)
    }

    private func store(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
}
