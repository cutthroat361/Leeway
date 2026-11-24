import AppKit
import SwiftUI

/// What Settings can ask the app to do, each for one account (by id).
struct SettingsActions {
    let signInWithBrowser: (String) -> Void
    let saveSessionKey: (String, String) -> Void
    let signOut: (String) -> Void
    let refresh: (String) -> Void
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case account = "Account"
    case menuBar = "Menu bar"
    case alerts = "Alerts"
    case general = "General"
    var id: String { rawValue }
}

/// Reports the height Settings needs, so the window can fit the selected tab.
private struct SettingsHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct SettingsView: View {
    static let width: CGFloat = 560

    @ObservedObject var model: AccountsModel
    @ObservedObject var settings: AppSettings
    let actions: SettingsActions
    /// Called with the height the window's content needs for the selected tab.
    let onHeightChange: (CGFloat) -> Void

    // View state is declared without the @State attribute on purpose: newer Apple
    // command line tools treat @State as a macro whose plugin only ships with Xcode.
    private let _tab = State<SettingsTab>(initialValue: .account)
    private var tab: SettingsTab {
        get { _tab.wrappedValue }
        nonmutating set { _tab.wrappedValue = newValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Settings section", selection: _tab.projectedValue) {
                ForEach(SettingsTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(SegmentedPickerStyle())
            .labelsHidden()
            .fixedSize()
            .padding(.top, 14)

            selectedTab
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 20)

            Divider()
            footer
        }
        .frame(width: SettingsView.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: SettingsHeightKey.self, value: proxy.size.height)
        })
        .onPreferenceChange(SettingsHeightKey.self) { height in
            onHeightChange(height)
        }
    }

    @ViewBuilder private var selectedTab: some View {
        switch tab {
        case .account: AccountTab(model: model, settings: settings, actions: actions)
        case .menuBar: MenuBarTab(settings: settings)
        case .alerts: AlertsTab(settings: settings)
        case .general: GeneralTab(model: model, settings: settings)
        }
    }

    private var footer: some View {
        HStack {
            Text("Leeway \(AppInfo.version)")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
            Button("View on GitHub") {
                if let url = URL(string: AppInfo.projectURL) {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(LinkButtonStyle())
            .font(.system(size: 11))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
    }
}

// MARK: Account

struct AccountTab: View {
    @ObservedObject var model: AccountsModel
    @ObservedObject var settings: AppSettings
    let actions: SettingsActions

    // View state is declared without the @State attribute on purpose: newer Apple
    // command line tools treat @State as a macro whose plugin only ships with Xcode.
    private let _selected = State<String>(initialValue: "")
    private var selected: String {
        get { _selected.wrappedValue }
        nonmutating set { _selected.wrappedValue = newValue }
    }
    private let _keyInput = State<String>(initialValue: "")
    private var keyInput: String {
        get { _keyInput.wrappedValue }
        nonmutating set { _keyInput.wrappedValue = newValue }
    }
    private let _claudeCodeFound = State<Bool?>(initialValue: nil)
    private var claudeCodeFound: Bool? {
        get { _claudeCodeFound.wrappedValue }
        nonmutating set { _claudeCodeFound.wrappedValue = newValue }
    }
    private let _showKeySteps = State<Bool>(initialValue: false)
    private var showKeySteps: Bool {
        get { _showKeySteps.wrappedValue }
        nonmutating set { _showKeySteps.wrappedValue = newValue }
    }

    /// The account being edited: the one picked above, or the first.
    private var accountId: String {
        settings.account(selected) != nil ? selected : (settings.accounts.first?.id ?? "")
    }
    private var account: Account? { settings.account(accountId) }
    private var store: UsageStore? { model.store(for: accountId) }
    private var hasKey: Bool { store?.client.hasSessionKey ?? false }
    private var several: Bool { settings.accounts.count > 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            accountRow
            if let account = account {
                Text(several ? "How should Leeway read \(account.displayName)'s usage?" : "How should Leeway read your usage?")
                    .font(.system(size: 13, weight: .semibold))
                Picker("Sign-in method", selection: Binding(
                    get: { account.authMethod },
                    set: { method in settings.updateAccount(accountId) { $0.authMethod = method } })) {
                    ForEach(AuthMethod.allCases) { method in
                        Text(method.title).tag(method)
                    }
                }
                .pickerStyle(RadioGroupPickerStyle())
                .labelsHidden()

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        methodDetail(account)
                        organizationPicker(account)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }

                connectionStatus
            }
        }
        .onAppear {
            checkClaudeCode()
            loadOrganizationsIfSignedIn()
        }
    }

    /// Pick an account, name it, add a second one or remove one.
    private var accountRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if several {
                    Picker("Account", selection: Binding(
                        get: { accountId },
                        set: { id in
                            selected = id
                            keyInput = ""
                            showKeySteps = false
                            DispatchQueue.main.async { loadOrganizationsIfSignedIn() }
                        })) {
                        ForEach(settings.accounts) { account in
                            Text(account.displayName).tag(account.id)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .labelsHidden()
                    .fixedSize()
                }
                Spacer()
                if settings.accounts.count < AppSettings.maxAccounts {
                    Button("Add a second account") {
                        if let added = settings.addAccount() {
                            selected = added.id
                            keyInput = ""
                        }
                    }
                    .help("Watch another Claude account, for example your work account next to your personal one")
                }
                if several {
                    Button("Remove…") { confirmRemove() }
                }
            }
            if several {
                HStack(spacing: 8) {
                    Text("Name")
                    TextField("Personal", text: Binding(
                        get: { account?.name ?? "" },
                        set: { name in settings.updateAccount(accountId) { $0.name = String(name.prefix(24)) } }))
                        .frame(width: 180)
                    Text("Shown in the menu bar as its first letter.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    @ViewBuilder private func methodDetail(_ account: Account) -> some View {
        switch account.authMethod {
        case .claudeCode:
            Text("Reads the login Claude Code saved on this Mac, so there's nothing to type. It follows whichever account Claude Code is signed in to.")
                .fixedSize(horizontal: false, vertical: true)
            if claudeCodeFound == false {
                Text("No Claude Code login found. Install Claude Code, run `claude` in Terminal and sign in, then check again.")
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if claudeCodeFound == true {
                Text("Claude Code login found on this Mac.")
                    .foregroundColor(.green)
            }
            if settings.accounts.filter({ $0.authMethod == .claudeCode }).count > 1 {
                Text("Both accounts use the Claude Code login, so they show the same numbers. Sign the other one in with a claude.ai window instead.")
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Check again") {
                checkClaudeCode()
                actions.refresh(accountId)
            }

        case .browser:
            Text(several
                 ? "Opens claude.ai's sign-in page in a small window. Sign in with this account's email. Leeway keeps the session in your macOS Keychain and closes the window. Your other account stays signed in."
                 : "Opens claude.ai's sign-in page in a small window. Once you're in, Leeway keeps the session in your macOS Keychain and closes the window.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(hasKey ? "Sign in again" : "Sign in to Claude") { actions.signInWithBrowser(accountId) }
                if hasKey {
                    Button("Sign out") { actions.signOut(accountId) }
                }
            }

        case .sessionKey:
            Text("Paste the sessionKey cookie from claude.ai. Leeway keeps it in your macOS Keychain.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                SecureField("sk-ant-sid01-…", text: _keyInput.projectedValue)
                Button("Save key") {
                    actions.saveSessionKey(accountId, keyInput)
                    keyInput = ""
                }
                .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Button(showKeySteps ? "Hide the steps" : "Where do I find it?") {
                showKeySteps.toggle()
            }
            .buttonStyle(LinkButtonStyle())
            if showKeySteps {
                Text("1. Open claude.ai in your browser and sign in.\n2. Open the developer tools with Cmd+Option+I. In Safari, first turn on Settings > Advanced > Show features for web developers.\n3. Go to Application (Chrome, Edge) or Storage (Safari, Firefox), then Cookies, then https://claude.ai.\n4. Copy the value of sessionKey and paste it above.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if hasKey {
                Button("Remove saved key") { actions.signOut(accountId) }
            }
        }
    }

    @ViewBuilder private func organizationPicker(_ account: Account) -> some View {
        if account.authMethod.usesWebSession && hasKey, let store = store {
            if store.organizations.count > 1 {
                Picker("Organization", selection: Binding(
                    get: { account.orgId },
                    set: { newId in
                        if let org = store.organizations.first(where: { $0.id == newId }) {
                            store.selectOrganization(org)
                        }
                    })) {
                    ForEach(store.organizations) { org in
                        Text(org.name).tag(org.id)
                    }
                }
                .frame(maxWidth: 360)
            } else if !account.orgName.isEmpty {
                Text("Organization: \(account.orgName)")
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder private var connectionStatus: some View {
        if let store = store {
            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if store.isLoading {
                Text("Connecting…")
                    .foregroundColor(.secondary)
            } else if store.lastUpdated != nil {
                Label("Connected. \(TextFormat.updatedAgo(store.lastUpdated, now: Date())).",
                      systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
            }
        }
    }

    private func loadOrganizationsIfSignedIn() {
        if let account = account, account.authMethod.usesWebSession, hasKey {
            store?.loadOrganizations()
        }
    }

    private func confirmRemove() {
        guard let account = account else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(account.displayName)?"
        alert.informativeText = "Leeway forgets this account's sign-in and its usage history. Your Claude account itself isn't changed."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        settings.removeAccount(account.id)
        selected = settings.accounts.first?.id ?? ""
    }

    private func checkClaudeCode() {
        DispatchQueue.global(qos: .userInitiated).async {
            let found = ClaudeCodeCredentials.read() != nil
            DispatchQueue.main.async { claudeCodeFound = found }
        }
    }
}

// MARK: Menu bar

struct MenuBarTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Show Leeway in the menu bar", isOn: $settings.showInMenuBar)
            if !settings.showInMenuBar {
                Text("Leeway keeps running and updating its widget. To get back to Settings, click the widget or open Leeway from Applications.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 14) {
                Text("What should the menu bar show?")
                    .font(.system(size: 13, weight: .semibold))
                if settings.accounts.count > 1 {
                    accountChoice("Accounts", selection: $settings.display)
                }
                Picker("Menu bar style", selection: $settings.barStyle) {
                    ForEach(BarStyle.allCases) { style in
                        Text("\(style.title)   \(style.example)").tag(style)
                    }
                }
                .pickerStyle(RadioGroupPickerStyle())
                .labelsHidden()

                Toggle("Show the gauge icon next to the numbers", isOn: $settings.showIcon)
                    .disabled(settings.barStyle == .miniBars)
                Toggle("Turn numbers orange at 75% and red at 90%", isOn: $settings.colorWhenHigh)
            }
            .disabled(!settings.showInMenuBar)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Widget")
                    .font(.system(size: 13, weight: .semibold))
                if settings.accounts.count > 1 {
                    accountChoice("The widget shows", selection: $settings.widgetShows)
                }
                Text(MenuBarTab.widgetHelp)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Both accounts, or one of them.
    private func accountChoice(_ title: String, selection: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Text(title)
            Picker(title, selection: selection) {
                Text("Both").tag(DisplayChoice.both)
                ForEach(settings.accounts) { account in
                    Text(account.displayName).tag(account.id)
                }
            }
            .pickerStyle(SegmentedPickerStyle())
            .labelsHidden()
            .fixedSize()
        }
    }

    static var widgetHelp: String {
        if #available(macOS 14.0, *) {
            return "Leeway also has a widget for your desktop and Notification Center. Right-click the desktop, choose Edit Widgets, then search for Leeway."
        }
        return "Leeway's widget needs macOS 14 Sonoma or later."
    }
}

// MARK: Alerts

struct AlertsTab: View {
    @ObservedObject var settings: AppSettings
    // View state is declared without the @State attribute on purpose: newer Apple
    // command line tools treat @State as a macro whose plugin only ships with Xcode.
    private let _testResult = State<Notifier.TestResult?>(initialValue: nil)
    private var testResult: Notifier.TestResult? {
        get { _testResult.wrappedValue }
        nonmutating set { _testResult.wrappedValue = newValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Send notifications", isOn: $settings.alertsEnabled)
                .onChange(of: settings.alertsEnabled) { isOn in
                    if isOn { Notifier.shared.requestPermission() }
                }

            VStack(alignment: .leading, spacing: 8) {
                Toggle("When a limit reaches 75%", isOn: $settings.alertAt75)
                Toggle("When a limit reaches 90%", isOn: $settings.alertAt90)
                Toggle("When I hit a limit", isOn: $settings.alertAtLimit)
                Toggle("When I'm on pace to run out before the limit resets", isOn: $settings.paceWarning)
                Toggle("When my session resets after reaching 90%", isOn: $settings.notifyOnReset)
            }
            .padding(.leading, 20)
            .disabled(!settings.alertsEnabled)

            Text("Alerts cover your current session and your weekly limit. Each one fires once per limit window.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Send a test notification") {
                Notifier.shared.sendTest { result in testResult = result }
            }
            if let result = testResult {
                testFeedback(result)
            }
        }
    }
}

// MARK: Test notification feedback

extension AlertsTab {
    @ViewBuilder fileprivate func testFeedback(_ result: Notifier.TestResult) -> some View {
        switch result {
        case .sent:
            Label("Test sent. No banner? A Focus such as Do Not Disturb or Sleep may be on. The test is still in Notification Center.",
                  systemImage: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .bannersOff:
            VStack(alignment: .leading, spacing: 6) {
                Text("Test sent, but Leeway's alert style is set to None, so alerts only go to Notification Center. Choose Banners or Alerts in System Settings > Notifications > Leeway.")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Notification Settings") { Notifier.openNotificationSettings() }
                    .controlSize(.small)
            }
            .font(.system(size: 11))
            .foregroundColor(.orange)
        case .notAllowed:
            VStack(alignment: .leading, spacing: 6) {
                Text("Notifications are off for Leeway, so nothing was sent. Turn them on in System Settings > Notifications > Leeway.")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Notification Settings") { Notifier.openNotificationSettings() }
                    .controlSize(.small)
            }
            .font(.system(size: 11))
            .foregroundColor(.orange)
        }
    }
}

// MARK: General

struct GeneralTab: View {
    @ObservedObject var model: AccountsModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var updater: Updater = Updater.shared

    // View state is declared without the @State attribute on purpose: newer Apple
    // command line tools treat @State as a macro whose plugin only ships with Xcode.
    private let _launchAtLogin = State<Bool>(initialValue: LoginItem.isEnabled)
    private var launchAtLogin: Bool {
        get { _launchAtLogin.wrappedValue }
        nonmutating set { _launchAtLogin.wrappedValue = newValue }
    }
    private let _loginNote = State<String>(initialValue: "")
    private var loginNote: String {
        get { _loginNote.wrappedValue }
        nonmutating set { _loginNote.wrappedValue = newValue }
    }

    static func label(forMinutes minutes: Int) -> String {
        minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Check for new numbers every", selection: $settings.refreshMinutes) {
                ForEach(AppSettings.refreshChoices, id: \.self) { minutes in
                    Text(GeneralTab.label(forMinutes: minutes)).tag(minutes)
                }
            }
            .frame(maxWidth: 340)

            Toggle("Open Leeway when I log in", isOn: Binding(
                get: { launchAtLogin },
                set: { isOn in
                    loginNote = LoginItem.set(isOn) ?? ""
                    launchAtLogin = LoginItem.isEnabled
                }))
            if !loginNote.isEmpty {
                Text(loginNote)
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Clear usage history") {
                model.clearAllHistory()
            }

            Divider()

            updatesSection

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("About Leeway")
                    .font(.system(size: 12, weight: .semibold))
                Text("Reads your limits straight from claude.ai or Anthropic. Your sign-in stays in the macOS Keychain and your history stays on this Mac. Update checks only ask GitHub for the latest Leeway release.")
                Text("Leeway isn't made by or affiliated with Anthropic. It reads the same unofficial endpoint as the claude.ai usage page, so a change on their side can break it until Leeway is updated.")
            }
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Check for Leeway updates once a day", isOn: $settings.checkForUpdates)
            HStack(spacing: 10) {
                updateButton
                updateStatusText
            }
            if updater.availableVersion != nil {
                Text("After updating, macOS may ask to use the Keychain again. Click Always Allow.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var updateButton: some View {
        if let version = updater.availableVersion {
            Button("Update to \(version) now") { updater.installUpdate() }
        } else {
            Button("Check for updates") { updater.check(userInitiated: true) }
                .disabled(updater.isBusy)
        }
    }

    @ViewBuilder private var updateStatusText: some View {
        switch updater.status {
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…")
            }
            .font(.system(size: 11))
            .foregroundColor(.secondary)
        case .upToDate:
            Text("You have the latest version.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        case .available(let version):
            Text("Leeway \(version) is available.")
                .font(.system(size: 11))
                .foregroundColor(.accentColor)
        case .downloading(let version), .installing(let version):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Installing \(version). Leeway will reopen by itself.")
            }
            .font(.system(size: 11))
            .foregroundColor(.secondary)
        case .failed(let message):
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .idle:
            EmptyView()
        }
    }
}
