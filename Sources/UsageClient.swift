import Foundation

enum UsageError: Error {
    case notSignedIn(String)
    case expired(String)
    case badResponse(String)
    case network(String)

    var message: String {
        switch self {
        case .notSignedIn(let text), .expired(let text), .badResponse(let text), .network(let text):
            return text
        }
    }

    var needsSignIn: Bool {
        switch self {
        case .notSignedIn, .expired: return true
        case .badResponse, .network: return false
        }
    }
}

struct Organization: Identifiable, Equatable {
    let id: String
    let name: String
}

struct FetchResult {
    let windows: [UsageWindow]
    /// The organization that answered, when Leeway had to look it up.
    let org: Organization?
    let orgs: [Organization]
    /// Short description of where the numbers came from.
    let source: String?
}

/// Reads the login Claude Code saved on this Mac. Leeway never refreshes or
/// rewrites that login, so it can't break Claude Code.
enum ClaudeCodeCredentials {
    struct Token {
        let accessToken: String
        let expiresAt: Date?
        let subscription: String?

        var label: String {
            guard let plan = subscription, !plan.isEmpty else { return "Claude Code login" }
            return "Claude Code login, \(plan.capitalized) plan"
        }
    }

    static func read() -> Token? {
        if let json = readFromKeychain(), let token = parse(json) { return token }
        let file = NSHomeDirectory() + "/.claude/.credentials.json"
        if let data = FileManager.default.contents(atPath: file),
           let json = String(data: data, encoding: .utf8),
           let token = parse(json) {
            return token
        }
        return nil
    }

    /// Uses Apple's `security` tool because Claude Code created the item with it,
    /// so macOS doesn't ask for your password.
    private static func readFromKeychain() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parse(_ json: String) -> Token? {
        guard let data = json.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let oauth = (root["claudeAiOauth"] as? [String: Any]) ?? root
        guard let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        var expires: Date? = nil
        if let raw = oauth["expiresAt"] as? NSNumber {
            let value = raw.doubleValue
            expires = Date(timeIntervalSince1970: value > 1e12 ? value / 1000 : value)
        }
        return Token(accessToken: token, expiresAt: expires, subscription: oauth["subscriptionType"] as? String)
    }
}

/// Reads usage for one account. Each account has its own client, so two claude.ai
/// sign-ins never share a session key or a cookie.
final class UsageClient {
    static let browserUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    private static let http: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        return URLSession(configuration: config)
    }()

    /// The Keychain item that holds this account's claude.ai session key.
    let keychainAccount: String
    private var http: URLSession { UsageClient.http }
    private lazy var webFetcher = WebFetcher()
    private var cachedKey: String?
    private var didLoadKey = false

    init(keychainAccount: String) {
        self.keychainAccount = keychainAccount
    }

    // MARK: claude.ai session key

    var sessionKey: String? {
        if !didLoadKey {
            cachedKey = Keychain.get(account: keychainAccount)
            didLoadKey = true
        }
        return cachedKey
    }

    var hasSessionKey: Bool { !(sessionKey ?? "").isEmpty }

    func saveSessionKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        cachedKey = trimmed
        didLoadKey = true
        Keychain.set(trimmed, account: keychainAccount)
        webFetcher.reset()
    }

    func clearSessionKey() {
        cachedKey = nil
        didLoadKey = true
        Keychain.delete(account: keychainAccount)
        webFetcher.reset()
    }

    // MARK: Fetching

    /// Calls back on the main thread.
    func fetchUsage(method: AuthMethod, orgId: String?, completion: @escaping (Result<FetchResult, UsageError>) -> Void) {
        switch method {
        case .claudeCode:
            fetchFromClaudeCode(completion: completion)
        case .browser, .sessionKey:
            fetchFromWeb(method: method, orgId: orgId, completion: completion)
        }
    }

    private func fetchFromClaudeCode(completion: @escaping (Result<FetchResult, UsageError>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            guard let token = ClaudeCodeCredentials.read() else {
                DispatchQueue.main.async {
                    completion(.failure(.notSignedIn("No Claude Code login found on this Mac. Run `claude` in Terminal and sign in, then refresh.")))
                }
                return
            }
            guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else { return }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Leeway/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")

            self.http.dataTask(with: request) { data, response, error in
                let result: Result<FetchResult, UsageError>
                if let error = error {
                    result = .failure(.network("Can't reach Anthropic right now: \(error.localizedDescription)"))
                } else {
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    switch status {
                    case 200:
                        do {
                            let windows = try UsageParser.parse(data ?? Data())
                            result = .success(FetchResult(windows: windows, org: nil, orgs: [], source: token.label))
                        } catch let parseError as UsageError {
                            result = .failure(parseError)
                        } catch {
                            result = .failure(.badResponse(error.localizedDescription))
                        }
                    case 401:
                        result = .failure(.expired("Claude Code's login has expired. Run `claude` in Terminal once so it renews, then refresh."))
                    case 403:
                        result = .failure(.expired("This Claude Code login can't read usage. Run `claude`, type /login to sign in again, then refresh."))
                    case 429:
                        result = .failure(.network("Anthropic asked Leeway to slow down. It will try again at the next refresh."))
                    default:
                        result = .failure(.badResponse("Anthropic returned HTTP \(status)."))
                    }
                }
                DispatchQueue.main.async { completion(result) }
            }.resume()
        }
    }

    private func fetchFromWeb(method: AuthMethod, orgId: String?, completion: @escaping (Result<FetchResult, UsageError>) -> Void) {
        guard let key = sessionKey, !key.isEmpty else {
            let message = method == .browser
                ? "You're not signed in yet. Open Settings and click Sign in to Claude."
                : "No session key saved yet. Open Settings and paste one."
            completion(.failure(.notSignedIn(message)))
            return
        }

        guard let orgId = orgId, !orgId.isEmpty else {
            discoverOrganizations(key: key, preferred: nil, completion: completion)
            return
        }

        requestUsage(orgId: orgId, key: key) { result in
            switch result {
            case .success(let windows):
                completion(.success(FetchResult(windows: windows, org: nil, orgs: [], source: nil)))
            case .failure(let error):
                if case .network = error {
                    completion(.failure(error))
                } else {
                    // The saved organization may be gone; look them up again.
                    self.discoverOrganizations(key: key, preferred: orgId, completion: completion)
                }
            }
        }
    }

    func loadOrganizations(completion: @escaping (Result<[Organization], UsageError>) -> Void) {
        guard let key = sessionKey, !key.isEmpty else {
            completion(.failure(.notSignedIn("You're not signed in yet.")))
            return
        }
        getJSON(path: "/api/organizations", key: key) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let data):
                let orgs = UsageClient.parseOrganizations(data)
                if orgs.isEmpty {
                    completion(.failure(.badResponse("No organizations were found for this account.")))
                } else {
                    completion(.success(orgs))
                }
            }
        }
    }

    private func discoverOrganizations(key: String, preferred: String?, completion: @escaping (Result<FetchResult, UsageError>) -> Void) {
        loadOrganizations { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let orgs):
                var ordered = orgs
                if let preferred = preferred, let index = ordered.firstIndex(where: { $0.id == preferred }) {
                    let org = ordered.remove(at: index)
                    ordered.insert(org, at: 0)
                }
                self.tryOrganizations(ordered, index: 0, key: key, all: orgs, completion: completion)
            }
        }
    }

    /// Some accounts belong to several organizations (for example an API org and a Team org).
    /// Use the first one that has usage limits.
    private func tryOrganizations(_ orgs: [Organization], index: Int, key: String, all: [Organization],
                                  completion: @escaping (Result<FetchResult, UsageError>) -> Void) {
        guard index < orgs.count else {
            completion(.failure(.badResponse("None of your organizations returned usage limits.")))
            return
        }
        let org = orgs[index]
        requestUsage(orgId: org.id, key: key) { result in
            switch result {
            case .success(let windows):
                completion(.success(FetchResult(windows: windows, org: org, orgs: all, source: org.name)))
            case .failure(let error):
                if case .network = error {
                    completion(.failure(error))
                } else {
                    self.tryOrganizations(orgs, index: index + 1, key: key, all: all, completion: completion)
                }
            }
        }
    }

    private func requestUsage(orgId: String, key: String, completion: @escaping (Result<[UsageWindow], UsageError>) -> Void) {
        getJSON(path: "/api/organizations/\(orgId)/usage", key: key) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let data):
                do {
                    completion(.success(try UsageParser.parse(data)))
                } catch let parseError as UsageError {
                    completion(.failure(parseError))
                } catch {
                    completion(.failure(.badResponse(error.localizedDescription)))
                }
            }
        }
    }

    /// GET from claude.ai with the session cookie. If Cloudflare answers with a
    /// check page instead of JSON, retry through a hidden WebKit view.
    private func getJSON(path: String, key: String, completion: @escaping (Result<Data, UsageError>) -> Void) {
        guard let url = URL(string: "https://claude.ai" + path) else {
            completion(.failure(.badResponse("Bad address: \(path)")))
            return
        }
        var request = URLRequest(url: url)
        request.setValue("sessionKey=\(key)", forHTTPHeaderField: "Cookie")
        request.setValue(UsageClient.browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://claude.ai/settings/usage", forHTTPHeaderField: "Referer")

        http.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(.network("Can't reach claude.ai right now: \(error.localizedDescription)")))
                    return
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let body = data ?? Data()
                let isJSON = (try? JSONSerialization.jsonObject(with: body)) != nil
                if status == 200 && isJSON {
                    completion(.success(body))
                    return
                }
                if !isJSON && (status == 200 || status == 403 || status == 503) {
                    self.webFetcher.get(path: path, sessionKey: key, completion: completion)
                    return
                }
                completion(.failure(UsageClient.webError(status: status)))
            }
        }.resume()
    }

    static func webError(status: Int) -> UsageError {
        switch status {
        case 401, 403:
            return .expired("Your claude.ai sign-in has expired. Open Settings and sign in again.")
        case 404:
            return .badResponse("claude.ai has no usage data for this organization.")
        case 429:
            return .network("claude.ai asked Leeway to slow down. It will try again at the next refresh.")
        default:
            return .badResponse("claude.ai returned HTTP \(status).")
        }
    }

    static func parseOrganizations(_ data: Data) -> [Organization] {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard let id = (item["uuid"] as? String) ?? (item["id"] as? String) else { return nil }
            let name = (item["name"] as? String) ?? "Organization"
            return Organization(id: id, name: name)
        }
    }
}
