import AppKit
import WebKit

/// Shows claude.ai's own sign-in page. As soon as claude.ai sets its session
/// cookie, Leeway saves it to the Keychain and closes the window.
final class SignInWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
    private let onSessionKey: (String) -> Void
    private var webView: WKWebView?
    private var popups: [NSWindow] = []
    private var finished = false
    private var observing = false

    init(onSessionKey: @escaping (String) -> Void) {
        self.onSessionKey = onSessionKey
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = "Sign in to Claude"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 520)
        super.init(window: window)
        window.delegate = self
        buildContent(in: window)
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func buildContent(in window: NSWindow) {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 760))

        let tip = NSTextField(wrappingLabelWithString:
            "Sign in the way you normally do. If Google sign-in is blocked here, choose Continue with email and type the code from the email. This window closes by itself once you're in.")
        tip.font = NSFont.systemFont(ofSize: 12)
        tip.textColor = .secondaryLabelColor
        tip.preferredMaxLayoutWidth = 490
        tip.translatesAutoresizingMaskIntoConstraints = false

        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        let web = WKWebView(frame: .zero, configuration: config)
        web.customUserAgent = UsageClient.browserUserAgent
        web.navigationDelegate = self
        web.uiDelegate = self
        web.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(tip)
        container.addSubview(web)
        NSLayoutConstraint.activate([
            tip.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            tip.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            tip.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            web.topAnchor.constraint(equalTo: tip.bottomAnchor, constant: 10),
            web.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            web.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        window.contentView = container
        webView = web
    }

    func start() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Start clean so Leeway captures the account you sign in with now.
        WebData.clearClaudeData { [weak self] in
            guard let self = self else { return }
            WKWebsiteDataStore.default().httpCookieStore.add(self)
            self.observing = true
            if let url = URL(string: "https://claude.ai/login") {
                self.webView?.load(URLRequest(url: url))
            }
        }
    }

    // MARK: Cookie watching

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        checkForSession(in: cookieStore)
    }

    /// Backup for the cookie observer, which some macOS versions don't call
    /// reliably: look for the session cookie after every page load too.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard observing, !finished else { return }
        checkForSession(in: WKWebsiteDataStore.default().httpCookieStore)
    }

    private func checkForSession(in cookieStore: WKHTTPCookieStore) {
        cookieStore.getAllCookies { [weak self] cookies in
            guard let self = self, !self.finished else { return }
            let session = cookies.first { cookie in
                cookie.name == "sessionKey" && cookie.domain.hasSuffix("claude.ai") && !cookie.value.isEmpty
            }
            if let session = session {
                self.finish(with: session.value)
            }
        }
    }

    private func finish(with key: String) {
        finished = true
        stopObserving()
        onSessionKey(key)
        close()
    }

    private func stopObserving() {
        if observing {
            WKWebsiteDataStore.default().httpCookieStore.remove(self)
            observing = false
        }
    }

    func windowWillClose(_ notification: Notification) {
        stopObserving()
        webView?.stopLoading()
        popups.forEach { $0.close() }
        popups.removeAll()
    }

    // MARK: Pop-up windows (Google and Apple sign-in open these)

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let popupView = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640), configuration: configuration)
        popupView.customUserAgent = UsageClient.browserUserAgent
        popupView.uiDelegate = self

        let popupWindow = NSWindow(contentRect: popupView.frame,
                                   styleMask: [.titled, .closable, .resizable],
                                   backing: .buffered,
                                   defer: false)
        popupWindow.title = "Sign in"
        popupWindow.isReleasedWhenClosed = false
        popupWindow.contentView = popupView
        popupWindow.center()
        popupWindow.makeKeyAndOrderFront(nil)
        popups.append(popupWindow)
        return popupView
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let popupWindow = popups.first(where: { $0.contentView === webView }) {
            popupWindow.close()
            popups.removeAll { $0 === popupWindow }
        }
    }
}
