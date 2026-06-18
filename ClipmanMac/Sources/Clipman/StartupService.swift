import Foundation

final class StartupService {
    private let label = "com.andrelouis.clipman.login"

    private var launchAgentsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
    }

    private var plistURL: URL {
        launchAgentsDirectory.appendingPathComponent("\(label).plist")
    }

    func isEnabled() -> Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    func setEnabled(_ enabled: Bool, appBundleURL: URL) throws {
        if enabled {
            try enable(appBundleURL: appBundleURL)
        } else {
            try disable()
        }
    }

    private func enable(appBundleURL: URL) throws {
        try FileManager.default.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [
                "/usr/bin/open",
                appBundleURL.path
            ],
            "RunAtLoad": true
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: [.atomic])
        _ = runLaunchctl(arguments: ["bootout", "gui/\(getuid())", plistURL.path])
        _ = runLaunchctl(arguments: ["bootstrap", "gui/\(getuid())", plistURL.path])
    }

    private func disable() throws {
        _ = runLaunchctl(arguments: ["bootout", "gui/\(getuid())", plistURL.path])
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    private func runLaunchctl(arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
