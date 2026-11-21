import AppKit
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings.shared
    private var store: UsageStore!
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var signInController: SignInWindowController?
    private var refreshTimer: Timer?
    private var clockTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var activeAuth: AuthMethod = .browser
    private var activeInterval = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = UsageStore(settings: settings)
        installMainMenu()
        Notifier.shared.start()

        // First launch: use Claude Code's login if it's already on this Mac.
        let firstLaunch = !settings.hasCompletedSetup
        if firstLaunch {
            settings.authMethod = ClaudeCodeCredentials.read() != nil ? .claudeCode : .browser
        }

        installStatusItem()
        installPopover()

        activeAuth = settings.authMethod
        activeInterval = settings.refreshMinutes
        store.onChange = { [weak self] in self?.storeDidChange() }
        settings.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.settingsDidChange() }
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.addObserver(self,
                                                          selector: #selector(systemDidWake),
                                                          name: NSWorkspace.didWakeNotification,
                                                          object: nil)

        scheduleTimers()
        updateStatusItem()
        store.refresh()

        if firstLaunch {
            settings.hasCompletedSetup = true
            if settings.alertsEnabled { Notifier.shared.requestPermission() }
            if settings.authMethod != .claudeCode { openSettings() }
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
        let root = PopoverView(store: store,
                               settings: settings,
                               onRefresh: { [weak self] in self?.store.refresh() },
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
        store.now = Date()
        fitPopover(force: true)
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()

        let isStale = store.lastUpdated.map { Date().timeIntervalSince($0) > 60 } ?? true
        if isStale && !store.isLoading { store.refresh() }
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
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Leeway", action: #selector(quitApp), keyEquivalent: "q").target = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func refreshNow() { store.refresh() }
    @objc private func openSettingsFromMenu() { openSettings() }
    @objc private func quitApp() { NSApp.terminate(nil) }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        StatusRenderer.render(button: button,
                              session: store.session,
                              weekly: store.weekly,
                              settings: settings,
                              hasError: store.errorMessage != nil,
                              now: Date())
    }

    private func storeDidChange() {
        updateStatusItem()
        if popover.isShown { fitPopover(force: false) }
    }

    private func settingsDidChange() {
        if settings.authMethod != activeAuth {
            activeAuth = settings.authMethod
            store.clear()
            store.refresh()
        }
        if settings.refreshMinutes != activeInterval {
            activeInterval = settings.refreshMinutes
            scheduleTimers()
        }
        updateStatusItem()
    }

    // MARK: Timers

    private func scheduleTimers() {
        refreshTimer?.invalidate()
        let interval = TimeInterval(max(1, settings.refreshMinutes) * 60)
        let refresh = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.store.refresh()
        }
        refresh.tolerance = interval * 0.1
        RunLoop.main.add(refresh, forMode: .common)
        refreshTimer = refresh

        // Keeps countdowns and "updated x ago" fresh without hitting the network.
        if clockTimer == nil {
            let clock = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
                self?.store.now = Date()
                self?.updateStatusItem()
            }
            clock.tolerance = 5
            RunLoop.main.add(clock, forMode: .common)
            clockTimer = clock
        }
    }

    @objc private func systemDidWake() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.store.refresh()
        }
    }

    // MARK: Windows

    func openSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let actions = SettingsActions(
                signInWithBrowser: { [weak self] in self?.startBrowserSignIn() },
                saveSessionKey: { [weak self] key in self?.saveSessionKey(key) },
                signOut: { [weak self] in self?.signOut() },
                refresh: { [weak self] in self?.store.refresh() })
            let view = SettingsView(store: store, settings: settings, actions: actions)
            let controller = NSHostingController(rootView: AnyView(view))
            let window = NSWindow(contentViewController: controller)
            window.title = "Leeway Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func startBrowserSignIn() {
        signInController?.close()
        let controller = SignInWindowController { [weak self] key in
            guard let self = self else { return }
            self.saveSessionKey(key)
            DispatchQueue.main.async {
                self.signInController = nil
                self.openSettings()
            }
        }
        signInController = controller
        controller.start()
    }

    private func saveSessionKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        UsageClient.shared.saveSessionKey(trimmed)
        settings.orgId = ""
        settings.orgName = ""
        store.clear()
        store.refresh()
    }

    private func signOut() {
        UsageClient.shared.clearSessionKey()
        settings.orgId = ""
        settings.orgName = ""
        WebData.clearClaudeData {}
        store.clear()
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
