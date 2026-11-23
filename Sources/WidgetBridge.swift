import Foundation
import WidgetKit

/// Saves the latest numbers for the widget and asks macOS to redraw it.
enum WidgetBridge {
    static func publish(session: UsageWindow?, weekly: UsageWindow?, updated: Date?,
                        subtitle: String, message: String?) {
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
        let snapshot = WidgetSnapshot(session: limit(session),
                                      weekly: limit(weekly),
                                      updated: updated,
                                      subtitle: subtitle,
                                      message: message)
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
