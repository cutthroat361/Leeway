import AppKit
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings.shared
    private var model: AccountsModel!
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var signInController: SignInWindowController?
    private var refreshTimer: Timer?
    private var clockTimer: Timer?
    private var updateTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var activeInterval = 0
    private var widgetSignature = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        // First launch: use Claude Code's login if it's already on this Mac.
        let firstLaunch = !settings.hasCompletedSetup
        if firstLaunch, let first = settings.accounts.first {
            let method: AuthMethod = ClaudeCodeCredentials.read() != nil ? .claudeCode : .browser
            settings.updateAccount(first.id) { $0.authMethod = method }
        }

        model = AccountsModel(settings: settings)
        installMainMenu()
        Notifier.shared.start()

        installStatusItem()
        statusItem.isVisible = settings.showInMenuBar
        installPopover()

        activeInterval = settings.refreshMinutes
        widgetSignature = currentWidgetSignature
        model.onChange = { [weak self] in self?.storeDidChange() }
        settings.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.settingsDidChange() }
            }
            .store(in: &cancellables)
        // The update banner changes the popover's height; macOS 11 and 12 need a nudge.
        Updater.shared.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self = self, self.popover.isShown else { return }
                    self.fitPopover(force: false)
                }
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.addObserver(self,
                                                          selector: #selector(systemDidWake),
                                                          name: NSWorkspace.didWakeNotification,
                                                          object: nil)

        // Redraw right away when the 12/24-hour setting, region or time zone changes.
        // (The 30-second clock timer catches anything these miss.)
        for name in [NSLocale.currentLocaleDidChangeNotification, .NSSystemTimeZoneDidChange] {
            NotificationCenter.default.addObserver(self,
                                                   selector: #selector(clockFormatDidChange),
                                                   name: name,
                                                   object: nil)
        }
        DistributedNotificationCenter.default().addObserver(self,
                                                            selector: #selector(clockFormatDidChange),
                                                            name: Notification.Name("AppleTimePreferencesChangedNotification"),
                                                            object: nil)

        scheduleTimers()
        updateStatusItem()
        model.refreshAll()
        scheduleUpdateChecks()

        if firstLaunch {
            settings.hasCompletedSetup = true
            if settings.alertsEnabled { Notifier.shared.requestPermission() }
            if settings.accounts.first?.authMethod != .claudeCode { openSettings() }
        }
    }

    // MARK: Menu bar item

    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func installPopover() {
        popover.behavior = .transient
        let root = PopoverView(model: model,
                               settings: settings,
                               onRefresh: { [weak self] in self?.model.refreshAll() },
                               onOpenSettings: { [weak self] in self?.openSettings() },
                               onQuit: { NSApp.terminate(nil) })
        let controller = NSHostingController(rootView: AnyView(root))
        if #available(macOS 13.0, *) {
            controller.sizingOptions = .preferredContentSize
        }
        popover.contentViewController = controller
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem.button else { return }
        model.tick()
        fitPopover(force: true)
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()

        model.refreshIfStale()
    }

    /// macOS 13+ sizes the popover from SwiftUI automatically; older versions need help.
    private func fitPopover(force: Bool) {
        if #available(macOS 13.0, *), !force { return }
        guard let view = popover.contentViewController?.view else { return }
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        if size.width > 10 && size.height > 10 {
            popover.contentSize = size
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Refresh now", action: #selector(refreshNow), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ",").target = self
        if let version = Updater.shared.availableVersion {
            menu.addItem(withTitle: "Update to Leeway \(version)", action: #selector(installUpdateFromMenu), keyEquivalent: "").target = self
        } else {
            menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdatesFromMenu), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Leeway", action: #selector(quitApp), keyEquivalent: "q").target = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func refreshNow() { model.refreshAll() }
    @objc private func openSettingsFromMenu() { openSettings() }
    @objc private func quitApp() { NSApp.terminate(nil) }
    @objc private func installUpdateFromMenu() { Updater.shared.installUpdate() }

    @objc private func checkForUpdatesFromMenu() {
        Updater.shared.check(userInitiated: true) { [weak self] in
            self?.showUpdateResult()
        }
    }

    /// Answers a "Check for Updates…" from the menu, since no window is open to show it.
    private func showUpdateResult() {
        let updater = Updater.shared
        let alert = NSAlert()
        switch updater.status {
        case .available(let version):
            alert.messageText = "Leeway \(version) is available"
            alert.informativeText = "You have \(AppInfo.version). Leeway will download the update, install it and reopen by itself. macOS may ask to use the Keychain again afterwards; click Always Allow."
            alert.addButton(withTitle: "Update now")
            alert.addButton(withTitle: "Later")
        case .failed(let message):
            alert.messageText = "Couldn't check for updates"
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
        default:
            alert.messageText = "You have the latest version"
            alert.informativeText = "Leeway \(AppInfo.version) is the newest release."
            alert.addButton(withTitle: "OK")
        }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn, updater.availableVersion != nil {
            updater.installUpdate()
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let shown = model.displayed
        let several = shown.count > 1
        let items = shown.map { store in
            StatusRenderer.Item(label: several ? store.account?.initial : nil,
                                name: several ? store.account?.displayName : nil,
                                session: store.session,
                                weekly: store.weekly,
                                hasError: store.errorMessage != nil)
        }
        StatusRenderer.render(button: button, items: items, settings: settings, now: Date())
    }

    private func storeDidChange() {
        updateStatusItem()
        if popover.isShown { fitPopover(force: false) }
    }

    private func settingsDidChange() {
        if currentWidgetSignature != widgetSignature {
            widgetSignature = currentWidgetSignature
            model.publishToWidget()
        }
        if popover.isShown { fitPopover(force: false) }
        if settings.refreshMinutes != activeInterval {
            activeInterval = settings.refreshMinutes
            scheduleTimers()
        }
        if statusItem.isVisible != settings.showInMenuBar {
            if !settings.showInMenuBar { popover.performClose(nil) }
            statusItem.isVisible = settings.showInMenuBar
        }
        updateStatusItem()
    }

    // MARK: Opening Leeway from the widget or from Applications

    /// The widget opens leeway://open when clicked.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.contains(where: { $0.scheme == "leeway" }) else { return }
        DispatchQueue.main.async { [weak self] in self?.showMainUI() }
    }

    /// Opening Leeway again from Applications or Spotlight while it's running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    /// The popover when Leeway is in the menu bar, Settings when it isn't.
    private func showMainUI() {
        if settings.showInMenuBar && statusItem.isVisible {
            if !popover.isShown { togglePopover() }
        } else {
            openSettings()
        }
    }

    // MARK: Timers

    private func scheduleTimers() {
        refreshTimer?.invalidate()
        let interval = TimeInterval(max(1, settings.refreshMinutes) * 60)
        let refresh = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.model.refreshAll()
        }
        refresh.tolerance = interval * 0.1
        RunLoop.main.add(refresh, forMode: .common)
        refreshTimer = refresh

        // Keeps countdowns and "updated x ago" fresh without hitting the network.
        if clockTimer == nil {
            let clock = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
                self?.model.tick()
                self?.updateStatusItem()
            }
            clock.tolerance = 5
            RunLoop.main.add(clock, forMode: .common)
            clockTimer = clock
        }
    }

    /// Checks GitHub shortly after launch, then once a day, while the setting is on.
    private func scheduleUpdateChecks() {
        let checkIfEnabled = { [weak self] in
            guard let self = self, self.settings.checkForUpdates else { return }
            Updater.shared.check(userInitiated: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: checkIfEnabled)
        let timer = Timer(timeInterval: 24 * 60 * 60, repeats: true) { _ in checkIfEnabled() }
        timer.tolerance = 60 * 60
        RunLoop.main.add(timer, forMode: .common)
        updateTimer = timer
    }

    @objc private func clockFormatDidChange() {
        DispatchQueue.main.async { [weak self] in
            self?.model.tick()
            self?.updateStatusItem()
        }
    }

    @objc private func systemDidWake() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.model.refreshAll()
        }
    }

    // MARK: Windows

    func openSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let actions = SettingsActions(
                signInWithBrowser: { [weak self] id in self?.startBrowserSignIn(for: id) },
                saveSessionKey: { [weak self] id, key in self?.saveSessionKey(key, for: id) },
                signOut: { [weak self] id in self?.signOut(id) },
                refresh: { [weak self] id in self?.model.store(for: id)?.refresh() })
            let view = SettingsView(model: model, settings: settings, actions: actions,
                                    onHeightChange: { [weak self] height in
                                        DispatchQueue.main.async { self?.fitSettingsWindow(toHeight: height) }
                                    })
            let controller = NSHostingController(rootView: AnyView(view))
            if #available(macOS 13.0, *) {
                // The window is sized by fitSettingsWindow, so it can animate between tabs.
                controller.sizingOptions = []
            }
            let window = NSWindow(contentViewController: controller)
            window.title = "Leeway Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            let fitted = controller.sizeThatFits(in: NSSize(width: SettingsView.width, height: 2000))
            window.setContentSize(NSSize(width: SettingsView.width, height: max(200, ceil(fitted.height))))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Fits the Settings window to the selected tab, keeping its top edge in place.
    private func fitSettingsWindow(toHeight height: CGFloat) {
        guard let window = settingsWindow, height > 0 else { return }
        let content = window.contentRect(forFrameRect: window.frame)
        let size = NSSize(width: SettingsView.width, height: ceil(height))
        guard abs(content.height - size.height) > 0.5 || abs(content.width - size.width) > 0.5 else { return }
        let newContent = NSRect(x: content.minX, y: content.maxY - size.height,
                                width: size.width, height: size.height)
        window.setFrame(window.frameRect(forContentRect: newContent), display: true, animate: window.isVisible)
    }

    private func startBrowserSignIn(for accountId: String) {
        signInController?.close()
        let several = settings.accounts.count > 1
        let name = settings.account(accountId)?.displayName
        let title = several && name != nil ? "Sign in to Claude - \(name!)" : "Sign in to Claude"
        let controller = SignInWindowController(title: title) { [weak self] key in
            guard let self = self else { return }
            self.saveSessionKey(key, for: accountId)
            DispatchQueue.main.async {
                self.signInController = nil
                self.openSettings()
            }
        }
        signInController = controller
        controller.start()
    }

    private func saveSessionKey(_ key: String, for accountId: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let store = model.store(for: accountId) else { return }
        store.client.saveSessionKey(trimmed)
        settings.updateAccount(accountId) { account in
            account.orgId = ""
            account.orgName = ""
        }
        store.clear()
        store.refresh()
    }

    private func signOut(_ accountId: String) {
        guard let store = model.store(for: accountId) else { return }
        store.client.clearSessionKey()
        settings.updateAccount(accountId) { account in
            account.orgId = ""
            account.orgName = ""
        }
        // Sign-ins before Leeway 1.4 also left cookies in WebKit's shared store.
        WebData.clearClaudeData {}
        store.clear()
    }

    /// Changes whenever the widget should show something else.
    private var currentWidgetSignature: String {
        settings.widgetShows + "|" + settings.accounts.map { "\($0.id)=\($0.displayName)" }.joined(separator: ",")
    }

    // MARK: Main menu

    /// Menu bar apps have no visible menu, but text fields still need Edit
    /// shortcuts (Cmd+V to paste a session key, Cmd+W to close windows).
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit Leeway", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }
}
