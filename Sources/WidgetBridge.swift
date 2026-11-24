import Foundation
import WidgetKit

/// Saves the latest numbers for the widget and asks macOS to redraw it.
enum WidgetBridge {
    struct Entry {
        let name: String
        let session: UsageWindow?
        let weekly: UsageWindow?
        let updated: Date?
        let subtitle: String
        let message: String?
    }

    static func publish(_ entries: [Entry]) {
        let now = Date()
        func limit(_ window: UsageWindow?) -> WidgetSnapshot.Limit? {
            guard let window = window else { return nil }
            let pace = window.pace(now: now)
            return WidgetSnapshot.Limit(used: window.used,
                                        resetsAt: window.resetsAt,
                                        length: window.length,
                                        paceText: pace.map { PaceText.text(for: $0, now: now) },
                                        paceLevel: pace.map { name(of: $0.level) })
        }
        let snapshot = WidgetSnapshot(accounts: entries.map { entry in
            WidgetSnapshot.Account(name: entry.name,
                                   session: limit(entry.session),
                                   weekly: limit(entry.weekly),
                                   updated: entry.updated,
                                   subtitle: entry.subtitle,
                                   message: entry.message)
        })
        do {
            let url = WidgetSnapshot.fileURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
        } catch {
            return
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    private static func name(of level: Pace.Level) -> String {
        switch level {
        case .relaxed: return "relaxed"
        case .steady: return "steady"
        case .tight: return "tight"
        case .runningOut: return "runningOut"
        case .atLimit: return "atLimit"
        }
    }
}
