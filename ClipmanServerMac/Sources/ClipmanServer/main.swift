import AppKit
import Darwin
import Foundation

final class ServerController: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var serverProcess: Process?
    private var quitting = false

    private var appBundle: Bundle { Bundle.main }
    private var resourceURL: URL { appBundle.resourceURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath) }
    private var scriptURL: URL { resourceURL.appendingPathComponent("clipman_server.py") }
    private var supportURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Clipman Server", isDirectory: true)
    }
    private var logsURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Clipman Server", isDirectory: true)
    }
    private var settingsURL: URL { supportURL.appendingPathComponent("clipman-server-settings.json") }
    private var connectionURL: URL { supportURL.appendingPathComponent("clipman-server-connection.txt") }
    private var wrapperLogURL: URL { logsURL.appendingPathComponent("clipman-server-wrapper.log") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        startServer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        quitting = true
        stopServer()
    }

    private func configureStatusItem() {
        statusItem.button?.title = "Clipman Server: Starting"
        statusItem.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let status = NSMenuItem(title: "Clipman Server: \(statusText())", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(NSMenuItem(title: "Copy Connection Details", action: #selector(copyConnectionDetails), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open Settings Folder", action: #selector(openSettingsFolder), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open Logs Folder", action: #selector(openLogsFolder), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Check for Updates", action: #selector(checkForUpdates), keyEquivalent: ""))
        let serverControlTitle = statusText() == "running" ? "Restart Server" : "Start Server"
        menu.addItem(NSMenuItem(title: serverControlTitle, action: #selector(restartServer), keyEquivalent: ""))
        let loginItem = NSMenuItem(title: "Run at Login", action: #selector(toggleRunAtLogin), keyEquivalent: "")
        loginItem.state = isRunAtLoginEnabled() ? .on : .off
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        return menu
    }

    private func refreshMenu() {
        statusItem.button?.title = "Clipman Server: \(statusText().capitalized)"
        statusItem.menu = buildMenu()
    }

    private func statusText() -> String {
        guard let process = serverProcess else { return "stopped" }
        return process.isRunning ? "running" : "stopped"
    }

    private func startServer() {
        do {
            try FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: logsURL, withIntermediateDirectories: true)
        } catch {
            showAlert("Could not create Clipman Server folders: \(error.localizedDescription)")
            return
        }

        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            showAlert("clipman_server.py was not found inside Clipman Server.app.")
            refreshMenu()
            return
        }

        guard let python = findPython() else {
            showAlert("Python 3 was not found. Install Python 3, then restart Clipman Server.")
            refreshMenu()
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [
            scriptURL.path,
            "--config", settingsURL.path
        ]
        process.currentDirectoryURL = resourceURL

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.appendLog(text)
        }

        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if !self.quitting {
                    self.refreshMenu()
                    self.showNotification("Clipman Server stopped. Use Start Server from the menu.")
                }
            }
        }

        do {
            try process.run()
            serverProcess = process
            refreshMenu()
            showNotification("Clipman Server started in the background.")
        } catch {
            appendLog(error.localizedDescription)
            showAlert("Clipman Server could not start: \(error.localizedDescription)")
            refreshMenu()
        }
    }

    private func stopServer() {
        guard let process = serverProcess else { return }
        if process.isRunning {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if process.isRunning {
                    process.interrupt()
                }
            }
        }
        serverProcess = nil
        refreshMenu()
    }

    @objc private func restartServer() {
        stopServer()
        startServer()
    }

    @objc private func copyConnectionDetails() {
        if let text = try? String(contentsOf: connectionURL, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            showNotification("Connection details copied.")
            return
        }

        guard let data = try? Data(contentsOf: settingsURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            showNotification("Connection details are not ready yet.")
            return
        }

        let host = object["Host"] as? String ?? ""
        let port = object["Port"] as? Int ?? 0
        let token = object["AuthToken"] as? String ?? ""
        let text = "Server address:\n\(host)\nPort:\n\(port)\nToken:\n\(token)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showNotification("Connection details copied.")
    }

    @objc private func openSettingsFolder() {
        NSWorkspace.shared.open(supportURL)
    }

    @objc private func openLogsFolder() {
        NSWorkspace.shared.open(logsURL)
    }

    @objc private func toggleRunAtLogin() {
        let enabled = !isRunAtLoginEnabled()
        setRunAtLogin(enabled)
        refreshMenu()
        showNotification(enabled ? "Clipman Server will run at login." : "Clipman Server login item removed.")
    }

    @objc private func checkForUpdates() {
        ServerUpdateService.checkForUpdates(silentInstall: false)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func findPython() -> String? {
        for path in ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"] {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    private var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.andrelouis.clipman-server.plist")
    }

    private func isRunAtLoginEnabled() -> Bool {
        FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    private func setRunAtLogin(_ enabled: Bool) {
        if enabled {
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
              <key>Label</key>
              <string>com.andrelouis.clipman-server</string>
              <key>ProgramArguments</key>
              <array>
                <string>\(appBundle.bundlePath)/Contents/MacOS/Clipman Server</string>
              </array>
              <key>RunAtLoad</key>
              <true/>
              <key>KeepAlive</key>
              <false/>
            </dict>
            </plist>
            """
            do {
                try FileManager.default.createDirectory(at: launchAgentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try plist.write(to: launchAgentURL, atomically: true, encoding: .utf8)
            } catch {
                showAlert("Could not save login item: \(error.localizedDescription)")
            }
        } else {
            try? FileManager.default.removeItem(at: launchAgentURL)
        }
    }

    private func appendLog(_ text: String) {
        do {
            try FileManager.default.createDirectory(at: logsURL, withIntermediateDirectories: true)
            let line = "\(Date()) \(text)"
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: wrapperLogURL.path),
                   let handle = try? FileHandle(forWritingTo: wrapperLogURL) {
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                    try handle.close()
                } else {
                    try data.write(to: wrapperLogURL)
                }
            }
        } catch {
        }
    }

    private func showNotification(_ text: String) {
        appendLog(text + "\n")
        statusItem.button?.toolTip = text
    }

    private func showAlert(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "Clipman Server"
        alert.informativeText = text
        alert.runModal()
    }
}

enum ServerUpdateService {
    private static let projectURL = URL(string: "https://github.com/OnjLouis/Clipman")!
    private static let releasesURL = URL(string: "https://api.github.com/repos/OnjLouis/Clipman/releases?per_page=20")!

    static func handleCommandLine() -> Bool {
        let args = CommandLine.arguments.dropFirst()
        if args.contains("--help") || args.contains("-h") {
            showAlert("""
            Clipman Server command line:
            --version
            --check-updates
            --install-update [--silent]
            --apply-update --update-url <url> --update-app <path> --update-wait-pid <pid>
            """)
            return true
        }
        if args.contains("--version") {
            showAlert(currentVersion())
            return true
        }
        if args.contains("--check-updates") {
            checkForUpdates(silentInstall: false)
            return true
        }
        if args.contains("--install-update") {
            checkForUpdates(silentInstall: args.contains("--silent") || args.contains("--yes"))
            return true
        }
        if args.contains("--apply-update") {
            applyUpdateFromCommandLine(Array(args))
            return true
        }
        return false
    }

    static func checkForUpdates(silentInstall: Bool) {
        do {
            guard let candidate = try latestServerAsset() else {
                if !silentInstall { showAlert("Could not find a Clipman Server release asset.") }
                return
            }
            guard compareVersions(candidate.version, currentVersion()) == .orderedDescending else {
                if !silentInstall { showAlert("Clipman Server is up to date. Current version: \(currentVersion()).") }
                return
            }

            if !silentInstall {
                let alert = NSAlert()
                alert.messageText = "Clipman Server \(candidate.version) is available."
                alert.informativeText = "Clipman Server will close, download the server ZIP, replace this Mac server app, and restart. Server settings and databases are kept in Application Support."
                alert.addButton(withTitle: "Update")
                alert.addButton(withTitle: "Later")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            startUpdate(downloadURL: candidate.downloadURL)
        } catch {
            if !silentInstall {
                showAlert("Could not check for Clipman Server updates:\n\n\(error.localizedDescription)")
            }
        }
    }

    private static func startUpdate(downloadURL: URL) {
        let appPath = Bundle.main.bundlePath
        let executablePath = Bundle.main.executablePath ?? ""
        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ClipmanServerUpdater-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            let updater = temp.appendingPathComponent("Clipman Server Updater")
            try FileManager.default.copyItem(atPath: executablePath, toPath: updater.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: updater.path)
            let process = Process()
            process.executableURL = updater
            process.arguments = [
                "--apply-update",
                "--update-url", downloadURL.absoluteString,
                "--update-app", appPath,
                "--update-wait-pid", String(ProcessInfo.processInfo.processIdentifier)
            ]
            process.currentDirectoryURL = temp
            try process.run()
            NSApp.terminate(nil)
        } catch {
            showAlert("Could not start Clipman Server updater:\n\n\(error.localizedDescription)")
        }
    }

    private static func applyUpdateFromCommandLine(_ args: [String]) {
        guard let zipURLText = value(after: "--update-url", in: args),
              let zipURL = URL(string: zipURLText),
              let appPath = value(after: "--update-app", in: args) else {
            showAlert("The updater was not given enough information to install the update.")
            return
        }
        if let pidText = value(after: "--update-wait-pid", in: args), let pid = Int32(pidText), pid > 0 {
            waitForProcess(pid)
        }

        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ClipmanServerUpdate-\(UUID().uuidString)", isDirectory: true)
        let zip = temp.appendingPathComponent("server.zip")
        let stage = temp.appendingPathComponent("stage", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
            let data = try Data(contentsOf: zipURL)
            try data.write(to: zip)
            try run("/usr/bin/unzip", ["-q", zip.path, "-d", stage.path])
            guard let sourceApp = findMacServerApp(in: stage) else {
                throw NSError(domain: "ClipmanServerUpdate", code: 1, userInfo: [NSLocalizedDescriptionKey: "The server update ZIP did not contain macOS/Clipman Server.app."])
            }
            try? FileManager.default.removeItem(atPath: appPath)
            try FileManager.default.copyItem(at: sourceApp, to: URL(fileURLWithPath: appPath))
            try? FileManager.default.removeItem(at: temp)
            NSWorkspace.shared.open(URL(fileURLWithPath: appPath))
        } catch {
            showAlert("Clipman Server update failed:\n\n\(error.localizedDescription)")
        }
    }

    private static func latestServerAsset() throws -> (version: String, downloadURL: URL)? {
        let data = try Data(contentsOf: releasesURL)
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return rows.compactMap { row -> (version: String, downloadURL: URL)? in
            let tag = ((row["tag_name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            guard !version.isEmpty,
                  let assets = row["assets"] as? [[String: Any]],
                  let asset = assets.first(where: {
                      let name = ($0["name"] as? String) ?? ""
                      return name.hasPrefix("ClipmanServer-") && name.hasSuffix(".zip")
                  }),
                  let urlText = asset["browser_download_url"] as? String,
                  let url = URL(string: urlText) else { return nil }
            return (version, url)
        }.sorted { compareVersions($0.version, $1.version) == .orderedDescending }.first
    }

    private static func findMacServerApp(in folder: URL) -> URL? {
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == "Clipman Server.app" && url.path.contains("/macOS/") {
                return url
            }
        }
        return nil
    }

    private static func currentVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    private static func compareVersions(_ left: String, _ right: String) -> ComparisonResult {
        let l = left.split(separator: ".").map { Int($0) ?? 0 }
        let r = right.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(l.count, r.count) {
            let lv = index < l.count ? l[index] : 0
            let rv = index < r.count ? r[index] : 0
            if lv < rv { return .orderedAscending }
            if lv > rv { return .orderedDescending }
        }
        return .orderedSame
    }

    private static func value(after option: String, in args: [String]) -> String? {
        for index in 0..<(args.count - 1) where args[index] == option {
            return args[index + 1]
        }
        return nil
    }

    private static func waitForProcess(_ pid: Int32) {
        for _ in 0..<300 {
            if kill(pid, 0) != 0 { return }
            usleep(100_000)
        }
    }

    private static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw NSError(domain: "ClipmanServerUpdate", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "\(executable) failed with exit code \(process.terminationStatus)."])
        }
    }

    private static func showAlert(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "Clipman Server"
        alert.informativeText = text
        alert.runModal()
    }
}

if ServerUpdateService.handleCommandLine() {
    exit(0)
}

let app = NSApplication.shared
let delegate = ServerController()
app.delegate = delegate
app.run()
