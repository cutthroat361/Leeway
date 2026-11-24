import AppKit
import WebKit

/// Helpers for the claude.ai data that WebKit keeps for Leeway.
enum WebData {
    static func clearClaudeData(completion: @escaping () -> Void) {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: types) { records in
            let claude = records.filter { $0.displayName.contains("claude.ai") }
            store.removeData(ofTypes: types, for: claude, completionHandler: completion)
        }
    }
}

/// Runs requests inside an off-screen WebKit view. A real browser engine passes
/// Cloudflare's checks that plain URLSession requests sometimes fail. Each fetcher
/// keeps its cookies in memory only, so two accounts never see each other's session.
final class WebFetcher: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var dataStore = WKWebsiteDataStore.nonPersistent()
    private var loadedKey: String?
    private var isReady = false
    private var waiting: [(Bool) -> Void] = []

    func reset() {
        webView?.stopLoading()
        webView = nil
        loadedKey = nil
        isReady = false
        flush(false)
    }

    func get(path: String, sessionKey: String, completion: @escaping (Result<Data, UsageError>) -> Void) {
        prepare(sessionKey: sessionKey) { [weak self] ok in
            guard let self = self, ok, let view = self.webView else {
                completion(.failure(.network("claude.ai is showing a security check Leeway couldn't pass. Open claude.ai in your browser once, then refresh.")))
                return
            }
            self.run(path: path, in: view, retried: false, completion: completion)
        }
    }

    private func prepare(sessionKey: String, then: @escaping (Bool) -> Void) {
        if webView != nil, loadedKey == sessionKey {
            if isReady { then(true) } else { waiting.append(then) }
            return
        }

        reset()
        waiting.append(then)
        loadedKey = sessionKey
        dataStore = WKWebsiteDataStore.nonPersistent()

        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        view.customUserAgent = UsageClient.browserUserAgent
        view.navigationDelegate = self
        webView = view

        let load = {
            if let url = URL(string: "https://claude.ai/robots.txt") {
                view.load(URLRequest(url: url))
            }
        }
        let properties: [HTTPCookiePropertyKey: Any] = [
            .domain: ".claude.ai",
            .path: "/",
            .name: "sessionKey",
            .value: sessionKey,
            .secure: "TRUE",
            .expires: Date().addingTimeInterval(30 * 86400)
        ]
        if let cookie = HTTPCookie(properties: properties) {
            config.websiteDataStore.httpCookieStore.setCookie(cookie) { load() }
        } else {
            load()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self, weak view] in
            guard let self = self, let view = view, self.webView === view, !self.isReady else { return }
            self.reset()
        }
    }

    private func run(path: String, in view: WKWebView, retried: Bool,
                     completion: @escaping (Result<Data, UsageError>) -> Void) {
        let script = """
        const response = await fetch(url, { credentials: "include", headers: { "Accept": "application/json" } });
        const text = await response.text();
        return JSON.stringify({ status: response.status, body: text });
        """
        view.callAsyncJavaScript(script, arguments: ["url": "https://claude.ai" + path], in: nil, in: .page) { [weak self] result in
            switch result {
            case .failure(let error):
                completion(.failure(.network("Couldn't reach claude.ai: \(error.localizedDescription)")))
            case .success(let value):
                guard let text = value as? String,
                      let wrapper = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
                      let status = (wrapper["status"] as? NSNumber)?.intValue,
                      let body = wrapper["body"] as? String else {
                    completion(.failure(.badResponse("claude.ai sent back something Leeway doesn't understand.")))
                    return
                }
                let bodyData = Data(body.utf8)
                let isJSON = (try? JSONSerialization.jsonObject(with: bodyData)) != nil
                if status == 200 && isJSON {
                    completion(.success(bodyData))
                    return
                }
                if !isJSON && !retried, let self = self {
                    // Give a challenge page a few seconds to finish, then try once more.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                        self.run(path: path, in: view, retried: true, completion: completion)
                    }
                    return
                }
                completion(.failure(UsageClient.webError(status: status)))
            }
        }
    }

    private func flush(_ ok: Bool) {
        let callbacks = waiting
        waiting.removeAll()
        callbacks.forEach { $0(ok) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        isReady = true
        flush(true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if webView === self.webView { reset() }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if webView === self.webView { reset() }
    }
}
