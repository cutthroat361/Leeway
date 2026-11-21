import SwiftUI

struct SettingsActions {
    let signInWithBrowser: () -> Void
    let saveSessionKey: (String) -> Void
    let signOut: () -> Void
    let refresh: () -> Void
}

struct SettingsView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: AppSettings
    let actions: SettingsActions

    var body: some View {
        TabView {
            AccountTab(store: store, settings: settings, actions: actions)
                .tabItem { Text("Account") }
            MenuBarTab(settings: settings)
                .tabItem { Text("Menu bar") }
            AlertsTab(settings: settings)
                .tabItem { Text("Alerts") }
            GeneralTab(store: store, settings: settings)
                .tabItem { Text("General") }
        }
        .padding(20)
        .frame(width: 560, height: 500)
    }
}

// MARK: Account

struct AccountTab: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: AppSettings
    let actions: SettingsActions

    @State private var keyInput = ""
    @State private var claudeCodeFound: Bool? = nil
    @State private var showKeySteps = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("How should Leeway read your usage?")
                .font(.system(size: 13, weight: .semibold))
            Picker("Sign-in method", selection: $settings.authMethod) {
                ForEach(AuthMethod.allCases) { method in
                    Text(method.title).tag(method)
                }
            }
            .pickerStyle(RadioGroupPickerStyle())
            .labelsHidden()

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    methodDetail
                    organizationPicker
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }

            connectionStatus
            Spacer()
        }
        .onAppear {
            checkClaudeCode()
            if settings.authMethod.usesWebSession && UsageClient.shared.hasSessionKey {
                store.loadOrganizations()
            }
        }
    }

    @ViewBuilder private var methodDetail: some View {
        switch settings.authMethod {
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
            Button("Check again") {
                checkClaudeCode()
                actions.refresh()
            }

        case .browser:
            Text("Opens claude.ai's sign-in page in a small window. Once you're in, Leeway keeps the session in your macOS Keychain and closes the window.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(signInTitle, action: actions.signInWithBrowser)
                if UsageClient.shared.hasSessionKey {
                    Button("Sign out", action: actions.signOut)
                }
            }

        case .sessionKey:
            Text("Paste the sessionKey cookie from claude.ai. Leeway keeps it in your macOS Keychain.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                SecureField("sk-ant-sid01-…", text: $keyInput)
                Button("Save key") {
                    actions.saveSessionKey(keyInput)
                    keyInput = ""
                }
                .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Button(keyStepsTitle) {
                showKeySteps.toggle()
            }
            .buttonStyle(LinkButtonStyle())
            if showKeySteps {
                Text("1. Open claude.ai in your browser and sign in.\n2. Open the developer tools with Cmd+Option+I. In Safari, first turn on Settings > Advanced > Show features for web developers.\n3. Go to Application (Chrome, Edge) or Storage (Safari, Firefox), then Cookies, then https://claude.ai.\n4. Copy the value of sessionKey and paste it above.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if UsageClient.shared.hasSessionKey {
                Button("Remove saved key", action: actions.signOut)
            }
        }
    }

    @ViewBuilder private var organizationPicker: some View {
        if settings.authMethod.usesWebSession && UsageClient.shared.hasSessionKey {
            if store.organizations.count > 1 {
                Picker("Organization", selection: Binding(
                    get: { settings.orgId },
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
            } else if !settings.orgName.isEmpty {
                Text("Organization: \(settings.orgName)")
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder private var connectionStatus: some View {
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

    private var signInTitle: String {
        UsageClient.shared.hasSessionKey ? "Sign in again" : "Sign in to Claude"
    }

    private var keyStepsTitle: String {
        showKeySteps ? "Hide the steps" : "Where do I find it?"
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
            Text("What should the menu bar show?")
                .font(.system(size: 13, weight: .semibold))
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
            Spacer()
        }
    }
}

// MARK: Alerts

struct AlertsTab: View {
    @ObservedObject var settings: AppSettings
    @State private var permissionNote = ""

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
                Notifier.shared.requestPermission { granted in
                    if granted {
                        permissionNote = ""
                        Notifier.shared.post(title: "Leeway alerts are on",
                                             body: "This is how a usage alert will look.")
                    } else {
                        permissionNote = "Notifications are off for Leeway. Turn them on in System Settings > Notifications > Leeway."
                    }
                }
            }
            if !permissionNote.isEmpty {
                Text(permissionNote)
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }
}

// MARK: General

struct GeneralTab: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: AppSettings

    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginNote = ""

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
                store.clearHistory()
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Leeway \(AppInfo.version)")
                    .font(.system(size: 12, weight: .semibold))
                Text("Reads your limits straight from claude.ai or Anthropic. Your sign-in stays in the macOS Keychain and your history stays on this Mac.")
                Text("Leeway isn't made by or affiliated with Anthropic. It reads the same unofficial endpoint as the claude.ai usage page, so a change on their side can break it until Leeway is updated.")
            }
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
    }
}
