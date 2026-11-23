import AppKit
import Foundation

/// Checks GitHub for a newer Leeway release and, when asked, installs it and restarts.
///
/// Only the zip attached to the latest release of the Leeway repository is used. Before
/// anything is replaced, the download must be Leeway (same bundle ID), newer than this
/// copy, and pass `codesign --verify`, which catches a damaged or altered bundle.
final class Updater: ObservableObject {
    static let shared = Updater()

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String)
        case downloading(version: String)
        case installing(version: String)
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var lastChecked: Date?

    static let releasesPage = URL(string: AppInfo.projectURL + "/releases/latest")!
    private static let latestReleaseAPI =
        URL(string: "https://api.github.com/repos/cutthroat361/Leeway/releases/latest")!
    private static let notifiedVersionKey = "notifiedUpdateVersion"

    private struct Release {
        let version: String
        let zipURL: URL
    }

    private var release: Release?

    var availableVersion: String? {
        if case .available(let version) = status { return version }
        return nil
    }

    var isBusy: Bool {
        switch status {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    // MARK: Checking

    /// Looks for a newer release. Automatic checks stay quiet when something goes wrong;
    /// `completion` runs on the main thread when the check is done.
    func check(userInitiated: Bool, completion: (() -> Void)? = nil) {
        guard !isBusy else { completion?(); return }
        status = .checking

        var request = URLRequest(url: Updater.latestReleaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Leeway/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData

        URLSession.shared.dataTask(with: request) { data, response, error in
            let result = Updater.parseRelease(data: data, response: response, error: error)
            DispatchQueue.main.async {
                self.lastChecked = Date()
                switch result {
                case .success(let release) where Updater.isVersion(release.version, newerThan: AppInfo.version):
                    self.release = release
                    self.status = .available(version: release.version)
                    if !userInitiated { self.announce(release.version) }
                case .success:
                    self.release = nil
                    self.status = .upToDate
                case .failure(let message):
                    self.status = userInitiated ? .failed(message) : .idle
                }
                completion?()
            }
        }.resume()
    }

    /// One notification per new version, so an automatic check doesn't go unnoticed.
    private func announce(_ version: String) {
        let defaults = UserDefaults.standard
        guard AppSettings.shared.alertsEnabled,
              defaults.string(forKey: Updater.notifiedVersionKey) != version else { return }
        defaults.set(version, forKey: Updater.notifiedVersionKey)
        Notifier.shared.post(title: "Leeway \(version) is available",
                             body: "Open Leeway in the menu bar and click Update now.")
    }

    private enum ParseResult {
        case success(Release)
        case failure(String)
    }

    private static func parseRelease(data: Data?, response: URLResponse?, error: Error?) -> ParseResult {
        if error != nil {
            return .failure("Couldn't reach GitHub. Check your internet connection and try again.")
        }
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        if statusCode == 403 || statusCode == 429 {
            return .failure("GitHub is limiting update checks right now. Try again in an hour.")
        }
        guard statusCode == 200,
              let data = data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else {
            return .failure("Couldn't read the latest release from GitHub.")
        }
        let assets = json["assets"] as? [[String: Any]] ?? []
        let zip = assets.first { asset in
            let name = asset["name"] as? String ?? ""
            return name.hasPrefix("Leeway") && name.hasSuffix(".zip")
        }
        guard let link = zip?["browser_download_url"] as? String,
              let url = URL(string: link),
              url.scheme == "https",
              url.host == "github.com" else {
            return .failure("The latest release doesn't have a download yet. Try again in a few minutes.")
        }
        return .success(Release(version: cleanVersion(tag), zipURL: url))
    }

    static func cleanVersion(_ tag: String) -> String {
        var version = tag.trimmingCharacters(in: .whitespaces)
        if version.hasPrefix("v") || version.hasPrefix("V") { version.removeFirst() }
        return version
    }

    /// Compares dotted version numbers: 1.10.0 is newer than 1.9.2.
    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        func parts(_ version: String) -> [Int] {
            cleanVersion(version).split(separator: ".").map { part in
                Int(part.prefix(while: { character in character.isNumber })) ?? 0
            }
        }
        let a = parts(candidate)
        let b = parts(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: Installing

    func installUpdate() {
        guard let release = release, !isBusy else { return }
        let appURL = Bundle.main.bundleURL
        let folder = appURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            status = .failed("Leeway can't replace itself in \(folder.path). Download the new version from GitHub instead.")
            NSWorkspace.shared.open(Updater.releasesPage)
            return
        }

        status = .downloading(version: release.version)
        URLSession.shared.downloadTask(with: release.zipURL) { tempFile, response, error in
            do {
                let newApp = try Updater.unpack(tempFile: tempFile, response: response, error: error)
                DispatchQueue.main.async {
                    self.status = .installing(version: release.version)
                    self.replaceAndRelaunch(currentApp: appURL, newApp: newApp)
                }
            } catch {
                let message = (error as? UpdateError)?.message ?? error.localizedDescription
                DispatchQueue.main.async { self.status = .failed(message) }
            }
        }.resume()
    }

    private struct UpdateError: Error {
        let message: String
    }

    /// Unzips the download and makes sure it's a newer, intact copy of Leeway.
    private static func unpack(tempFile: URL?, response: URLResponse?, error: Error?) throws -> URL {
        guard error == nil,
              let tempFile = tempFile,
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError(message: "The download didn't finish. Check your connection and try again.")
        }
        let fileManager = FileManager.default
        let work = fileManager.temporaryDirectory
            .appendingPathComponent("LeewayUpdate-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        let zip = work.appendingPathComponent("Leeway.zip")
        try fileManager.moveItem(at: tempFile, to: zip)

        let unzipped = work.appendingPathComponent("unzipped", isDirectory: true)
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, unzipped.path]) else {
            throw UpdateError(message: "The update couldn't be unzipped.")
        }
        let newApp = unzipped.appendingPathComponent("Leeway.app", isDirectory: true)
        guard let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")),
              let bundleID = info["CFBundleIdentifier"] as? String,
              bundleID == Bundle.main.bundleIdentifier,
              let version = info["CFBundleShortVersionString"] as? String,
              isVersion(version, newerThan: AppInfo.version) else {
            throw UpdateError(message: "The download isn't a newer copy of Leeway, so nothing was changed.")
        }
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path]) else {
            throw UpdateError(message: "The download looks damaged, so nothing was changed. Try again.")
        }
        return newApp
    }

    /// Hands over to a small script that waits for Leeway to quit, swaps in the new copy
    /// (restoring the old one if anything fails) and opens it.
    private func replaceAndRelaunch(currentApp: URL, newApp: URL) {
        let script = """
        pid="$1"; new="$2"; app="$3"; old="$3.previous"
        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
        rm -rf "$old"
        if mv "$app" "$old"; then
          if ditto "$new" "$app"; then
            rm -rf "$old"
          else
            rm -rf "$app"; mv "$old" "$app"
          fi
        fi
        xattr -dr com.apple.quarantine "$app" 2>/dev/null
        open "$app"
        rm -rf "$(dirname "$(dirname "$new")")"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "leeway-update",
                             String(ProcessInfo.processInfo.processIdentifier),
                             newApp.path, currentApp.path]
        do {
            try process.run()
        } catch {
            status = .failed("Couldn't start the update: \(error.localizedDescription)")
            return
        }
        NSApp.terminate(nil)
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
