import Foundation
import ServiceManagement

/// Launch at login. macOS 13 and newer use the system login item list;
/// macOS 11 and 12 use a small LaunchAgent in ~/Library/LaunchAgents.
enum LoginItem {
    private static let label = "io.github.cutthroat361.leeway.launcher"

    private static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            let status = SMAppService.mainApp.status
            return status == .enabled || status == .requiresApproval
        }
        return FileManager.default.fileExists(atPath: agentURL.path)
    }

    /// Returns a note for the person, or nil when it worked.
    static func set(_ enabled: Bool) -> String? {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                if enabled && SMAppService.mainApp.status == .requiresApproval {
                    return "Approve Leeway in System Settings > General > Login Items."
                }
                return nil
            } catch {
                return "Couldn't change the login item (\(error.localizedDescription)). Moving Leeway into your Applications folder usually fixes this."
            }
        }
        return setLaunchAgent(enabled)
    }

    private static func setLaunchAgent(_ enabled: Bool) -> String? {
        let fileManager = FileManager.default
        guard enabled else {
            try? fileManager.removeItem(at: agentURL)
            return nil
        }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath],
            "RunAtLoad": true
        ]
        do {
            try fileManager.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: agentURL, options: .atomic)
            return nil
        } catch {
            return "Couldn't add the login item: \(error.localizedDescription)"
        }
    }
}
