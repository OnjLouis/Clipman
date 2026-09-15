import Darwin
import Foundation

final class StartupService {
    typealias LaunchctlRunner = ([String]) -> Bool

    private enum RegistrationError: LocalizedError {
        case bootstrapFailed

        var errorDescription: String? {
            "macOS did not accept Clipman's Run at login registration."
        }
    }

    private static let launchctlTimeout: TimeInterval = 3
    private static let launchctlTerminationTimeout: TimeInterval = 1

    private let label = "com.andrelouis.clipman.login"
    private let fileManager: FileManager
    private let launchAgentsDirectory: URL
    private let launchctlRunner: LaunchctlRunner
    private let debugLogger: (String) -> Void

    init(
        fileManager: FileManager = .default,
        launchAgentsDirectory: URL? = nil,
        launchctlRunner: LaunchctlRunner? = nil,
        debugLogger: @escaping (String) -> Void = { _ in }
    ) {
        self.fileManager = fileManager
        self.launchAgentsDirectory = launchAgentsDirectory
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("LaunchAgents", isDirectory: true)
        self.launchctlRunner = launchctlRunner ?? Self.runLaunchctl
        self.debugLogger = debugLogger
    }

    private var plistURL: URL {
        launchAgentsDirectory.appendingPathComponent("\(label).plist")
    }

    func isEnabled() -> Bool {
        fileManager.fileExists(atPath: plistURL.path)
    }

    func setEnabled(_ enabled: Bool, appBundleURL: URL) throws {
        debugLogger("Login registration requested. enabled=\(enabled) registrationFileExists=\(isEnabled())")
        if enabled {
            try enable(appBundleURL: appBundleURL)
        } else {
            try disable()
        }
    }

    private func enable(appBundleURL: URL) throws {
        let registrationExists = fileManager.fileExists(atPath: plistURL.path)
        try fileManager.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)
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
        if registrationExists {
            _ = invokeLaunchctl(["bootout", "gui/\(getuid())", plistURL.path])
        }
        guard invokeLaunchctl(["bootstrap", "gui/\(getuid())", plistURL.path]) else {
            throw RegistrationError.bootstrapFailed
        }
        debugLogger("Login registration enabled successfully.")
    }

    private func disable() throws {
        guard fileManager.fileExists(atPath: plistURL.path) else {
            debugLogger("Login registration is already absent; no system command was needed.")
            return
        }
        _ = invokeLaunchctl(["bootout", "gui/\(getuid())", plistURL.path])
        try fileManager.removeItem(at: plistURL)
        debugLogger("Login registration disabled and its property list was removed.")
    }

    private func invokeLaunchctl(_ arguments: [String]) -> Bool {
        let action = arguments.first ?? "unknown"
        let started = ProcessInfo.processInfo.systemUptime
        debugLogger("launchctl \(action) started.")
        let succeeded = launchctlRunner(arguments)
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - started)
        debugLogger("launchctl \(action) finished. success=\(succeeded) elapsed=\(String(format: "%.3f", elapsed))s")
        return succeeded
    }

    private static func runLaunchctl(arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        do {
            try process.run()
        } catch {
            return false
        }

        if completed.wait(timeout: .now() + launchctlTimeout) == .timedOut {
            if process.isRunning {
                process.terminate()
            }
            if completed.wait(timeout: .now() + launchctlTerminationTimeout) == .timedOut {
                if process.isRunning {
                    Darwin.kill(process.processIdentifier, SIGKILL)
                }
                process.waitUntilExit()
            }
            return false
        }
        return process.terminationStatus == 0
    }
}
