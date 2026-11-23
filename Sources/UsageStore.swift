import Foundation
import Combine

final class UsageStore: ObservableObject {
    @Published private(set) var windows: [UsageWindow] = []
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var errorMessage: String?
    @Published private(set) var needsSignIn = false
    @Published private(set) var isLoading = false
    @Published private(set) var organizations: [Organization] = []
    @Published private(set) var sourceLabel = ""
    @Published private(set) var historyRevision = 0
    @Published var now = Date()

    let history = HistoryStore()
    var onChange: (() -> Void)?

    private let settings: AppSettings
    private let client = UsageClient.shared
    private var generation = 0

    init(settings: AppSettings) {
        self.settings = settings
    }

    var session: UsageWindow? {
        windows.first { $0.id == "five_hour" }
            ?? windows.first { $0.id.contains("five_hour") || $0.id.contains("session") }
    }

    var weekly: UsageWindow? {
        windows.first { $0.id == "seven_day" }
            ?? windows.first { window in
                (window.id.contains("seven_day") || window.id.contains("week"))
                    && !window.id.contains("opus") && !window.id.contains("sonnet")
            }
    }

    /// Session and weekly always show; model-specific limits show once they're in use.
    var visibleWindows: [UsageWindow] {
        let sessionId = session?.id
        let weeklyId = weekly?.id
        return windows.filter { $0.id == sessionId || $0.id == weeklyId || $0.utilization > 0 }
    }

    func refresh() {
        generation += 1
        let current = generation
        let method = settings.authMethod
        let orgId = settings.orgId.isEmpty ? nil : settings.orgId
        isLoading = true
        onChange?()

        client.fetchUsage(method: method, orgId: orgId) { [weak self] result in
            guard let self = self, current == self.generation else { return }
            self.isLoading = false
            switch result {
            case .success(let fetched):
                self.windows = fetched.windows
                self.lastUpdated = Date()
                self.errorMessage = nil
                self.needsSignIn = false
                if let org = fetched.org {
                    if self.settings.orgId != org.id { self.settings.orgId = org.id }
                    if self.settings.orgName != org.name { self.settings.orgName = org.name }
                }
                if !fetched.orgs.isEmpty { self.organizations = fetched.orgs }
                self.sourceLabel = fetched.source ?? self.settings.orgName
                self.history.add(session: self.session?.utilization, weekly: self.weekly?.utilization)
                self.historyRevision += 1
                Notifier.shared.evaluate(session: self.session, weekly: self.weekly, settings: self.settings)
            case .failure(let error):
                self.errorMessage = error.message
                self.needsSignIn = error.needsSignIn
            }
            self.now = Date()
            self.publishToWidget()
            self.onChange?()
        }
    }

    /// Keeps the widget in step with what the menu bar shows.
    private func publishToWidget() {
        WidgetBridge.publish(session: session,
                             weekly: weekly,
                             updated: lastUpdated,
                             subtitle: sourceLabel,
                             message: errorMessage)
    }

    /// Forget what's on screen, for example after switching accounts.
    func clear() {
        generation += 1
        isLoading = false
        windows = []
        lastUpdated = nil
        errorMessage = nil
        needsSignIn = false
        sourceLabel = ""
        organizations = []
        publishToWidget()
        onChange?()
    }

    func loadOrganizations() {
        client.loadOrganizations { [weak self] result in
            if case .success(let orgs) = result {
                self?.organizations = orgs
            }
        }
    }

    func selectOrganization(_ org: Organization) {
        guard org.id != settings.orgId else { return }
        settings.orgId = org.id
        settings.orgName = org.name
        windows = []
        refresh()
    }

    func clearHistory() {
        history.clear()
        historyRevision += 1
    }
}
