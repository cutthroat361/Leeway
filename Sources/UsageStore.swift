import Foundation
import Combine

/// The numbers for one account: what was fetched last, any error, and its history.
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

    let accountId: String
    let client: UsageClient
    let history: HistoryStore
    /// Called after every change, so the menu bar and widget can redraw.
    var onChange: (() -> Void)?

    private let settings: AppSettings
    private var generation = 0
    /// The sign-in method the numbers on screen came from.
    private(set) var activeMethod: AuthMethod

    init(account: Account, settings: AppSettings) {
        self.accountId = account.id
        self.settings = settings
        self.client = UsageClient(keychainAccount: account.keychainAccount)
        self.history = HistoryStore(fileName: account.historyFileName)
        self.activeMethod = account.authMethod
    }

    var account: Account? { settings.account(accountId) }

    /// The account's name, or nil while Leeway watches only one account.
    var labelIfSeveral: String? {
        settings.accounts.count > 1 ? account?.displayName : nil
    }

    /// The organization or login the numbers come from.
    var subtitle: String {
        guard let account = account else { return "" }
        if account.authMethod == .claudeCode { return sourceLabel }
        return account.orgName
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
        guard let account = account else { return }
        generation += 1
        let current = generation
        activeMethod = account.authMethod
        let orgId = account.orgId.isEmpty ? nil : account.orgId
        isLoading = true
        onChange?()

        client.fetchUsage(method: account.authMethod, orgId: orgId) { [weak self] result in
            guard let self = self, current == self.generation else { return }
            self.isLoading = false
            switch result {
            case .success(let fetched):
                self.windows = fetched.windows
                self.lastUpdated = Date()
                self.errorMessage = nil
                self.needsSignIn = false
                if let org = fetched.org {
                    self.settings.updateAccount(self.accountId) { account in
                        account.orgId = org.id
                        account.orgName = org.name
                    }
                }
                if !fetched.orgs.isEmpty { self.organizations = fetched.orgs }
                self.sourceLabel = fetched.source ?? (self.account?.orgName ?? "")
                self.history.add(session: self.session?.utilization, weekly: self.weekly?.utilization)
                self.historyRevision += 1
                Notifier.shared.evaluate(session: self.session, weekly: self.weekly, settings: self.settings,
                                         accountId: self.accountId, accountName: self.labelIfSeveral)
            case .failure(let error):
                self.errorMessage = error.message
                self.needsSignIn = error.needsSignIn
            }
            self.now = Date()
            self.onChange?()
        }
    }

    /// Forget what's on screen, for example after switching sign-in methods.
    func clear() {
        generation += 1
        isLoading = false
        windows = []
        lastUpdated = nil
        errorMessage = nil
        needsSignIn = false
        sourceLabel = ""
        organizations = []
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
        guard org.id != account?.orgId else { return }
        settings.updateAccount(accountId) { account in
            account.orgId = org.id
            account.orgName = org.name
        }
        windows = []
        refresh()
    }

    func clearHistory() {
        history.clear()
        historyRevision += 1
    }
}

/// All the accounts' stores, kept in step with the accounts in Settings.
final class AccountsModel: ObservableObject {
    @Published private(set) var stores: [UsageStore] = []
    /// Called after any account's numbers change.
    var onChange: (() -> Void)?

    private let settings: AppSettings
    private var cancellables = Set<AnyCancellable>()
    /// Passes each account's changes on to views that watch the model.
    private var forwarding: [String: AnyCancellable] = [:]

    init(settings: AppSettings) {
        self.settings = settings
        sync(settings.accounts, refreshNew: false)
        // $accounts sends the new list just before it's stored, so use the list it sends.
        settings.$accounts
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] accounts in self?.sync(accounts, refreshNew: true) }
            .store(in: &cancellables)
    }

    func store(for id: String) -> UsageStore? {
        stores.first { $0.accountId == id }
    }

    /// The stores the menu bar and popover show right now.
    var displayed: [UsageStore] {
        settings.displayedAccounts.compactMap { store(for: $0.id) }
    }

    var isLoading: Bool { stores.contains { $0.isLoading } }

    func refreshAll() {
        stores.forEach { $0.refresh() }
    }

    func tick(_ date: Date = Date()) {
        stores.forEach { $0.now = date }
    }

    /// Refreshes any account whose numbers are older than a minute.
    func refreshIfStale() {
        for store in stores where !store.isLoading {
            let isStale = store.lastUpdated.map { Date().timeIntervalSince($0) > 60 } ?? true
            if isStale { store.refresh() }
        }
    }

    func clearAllHistory() {
        stores.forEach { $0.clearHistory() }
    }

    /// Adds stores for new accounts, drops removed ones, and starts over for an
    /// account whose sign-in method changed.
    private func sync(_ accounts: [Account], refreshNew: Bool) {
        var next: [UsageStore] = []
        var added: [UsageStore] = []
        for account in accounts {
            if let existing = store(for: account.id) {
                if existing.activeMethod != account.authMethod {
                    existing.clear()
                    existing.refresh()
                }
                next.append(existing)
            } else {
                let store = UsageStore(account: account, settings: settings)
                store.onChange = { [weak self, weak store] in
                    guard let self = self, let store = store else { return }
                    // Redraw the widget once a refresh has finished, not while it runs.
                    if !store.isLoading { self.publishToWidget() }
                    self.onChange?()
                }
                forwarding[account.id] = store.objectWillChange.sink { [weak self] _ in
                    self?.objectWillChange.send()
                }
                next.append(store)
                added.append(store)
            }
        }
        let removed = stores.filter { old in !next.contains { $0 === old } }
        for store in removed {
            forwarding[store.accountId] = nil
            store.client.clearSessionKey()
            store.history.deleteFile()
        }
        let changed = !added.isEmpty || !removed.isEmpty
        stores = next
        if refreshNew { added.forEach { $0.refresh() } }
        if changed {
            publishToWidget()
            onChange?()
        }
    }

    /// Keeps the widget in step with the accounts chosen for it.
    func publishToWidget() {
        let chosen = DisplayChoice.accounts(for: settings.widgetShows, in: settings.accounts)
        let entries: [WidgetBridge.Entry] = chosen.compactMap { account in
            guard let store = store(for: account.id) else { return nil }
            return WidgetBridge.Entry(name: account.displayName,
                                      session: store.session,
                                      weekly: store.weekly,
                                      updated: store.lastUpdated,
                                      subtitle: store.subtitle,
                                      message: store.errorMessage)
        }
        WidgetBridge.publish(entries)
    }
}
