import Foundation
import UserNotifications

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private let firedKey = "firedAlerts"
    private let lastSessionKey = "lastSessionUtilization"

    func start() {
        UNUserNotificationCenter.current().delegate = self
    }

    func requestPermission(completion: ((Bool) -> Void)? = nil) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async { completion?(granted) }
        }
    }

    // Show banners even while Leeway is the active app.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    /// Called after every successful refresh. Each alert fires once per limit window.
    func evaluate(session: UsageWindow?, weekly: UsageWindow?, settings: AppSettings, now: Date = Date()) {
        let defaults = UserDefaults.standard
        var fired = (defaults.dictionary(forKey: firedKey) as? [String: Double]) ?? [:]
        let cutoff = now.addingTimeInterval(-9 * 86400).timeIntervalSince1970
        fired = fired.filter { $0.value > cutoff }
        let watched = [session, weekly].compactMap { $0 }

        if settings.alertsEnabled {
            var thresholds: [Int] = []
            if settings.alertAt75 { thresholds.append(75) }
            if settings.alertAt90 { thresholds.append(90) }
            if settings.alertAtLimit { thresholds.append(100) }

            for window in watched {
                let period = periodKey(window)
                let crossed = thresholds.filter { window.utilization >= Double($0) }
                let fresh = crossed.filter { fired["\(window.id).\($0).\(period)"] == nil }
                guard let top = fresh.max() else { continue }
                for threshold in fresh {
                    fired["\(window.id).\(threshold).\(period)"] = now.timeIntervalSince1970
                }
                let title = top >= 100
                    ? "\(window.title): limit reached"
                    : "\(window.title) is at \(TextFormat.percent(window.utilization))"
                post(title: title, body: TextFormat.resetSentence(window.resetsAt, now: now))
            }

            if settings.paceWarning {
                for window in watched {
                    guard let pace = window.pace(now: now),
                          pace.level == .runningOut,
                          let hit = pace.limitDate,
                          let reset = window.resetsAt,
                          pace.elapsedFraction >= 0.1,
                          window.utilization >= 15 else { continue }
                    let key = "\(window.id).pace.\(periodKey(window))"
                    guard fired[key] == nil else { continue }
                    fired[key] = now.timeIntervalSince1970
                    let limitName = window.id == "five_hour" ? "session limit" : "weekly limit"
                    post(title: "You're on pace to hit your \(limitName)",
                         body: "At this rate you'll run out around \(TextFormat.when(hit, now: now)), before it resets \(TextFormat.when(reset, now: now)).")
                }
            }

            if settings.notifyOnReset, let current = session,
               let previous = defaults.object(forKey: lastSessionKey) as? Double,
               previous >= 90, current.utilization < 20 {
                post(title: "Your Claude session has reset",
                     body: "You have \(TextFormat.percent(current.left)) of your session limit available again.")
            }
        }

        if let current = session {
            defaults.set(current.utilization, forKey: lastSessionKey)
        }
        defaults.set(fired, forKey: firedKey)
    }

    private func periodKey(_ window: UsageWindow) -> String {
        guard let reset = window.resetsAt else { return "none" }
        return String(Int(reset.timeIntervalSince1970 / 3600))
    }
}
