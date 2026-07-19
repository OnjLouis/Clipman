import AppKit
import Carbon
import ClipmanCore
import UniformTypeIdentifiers

private enum ExportPasswordChoice {
    case current
    case password(String)
    case none
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate, ClipStoreDelegate, FileHistoryStoreDelegate, ClipboardMonitorDelegate, HistoryWindowControllerDelegate, PreferencesWindowControllerDelegate, SecretsWindowControllerDelegate {
    private let settingsStore = SettingsStore()
    private let keychain = KeychainPasswordStore()
    private let serverTokenKeychain = KeychainPasswordStore(service: "Clipman.server.token")
    private let monitor = ClipboardMonitor()
    private let hotkeys = HotkeyManager()
    private let startup = StartupService()
    private let updates = UpdateService()
    private lazy var sounds = SoundService(applicationSupportURL: settingsStore.applicationSupportURL)
    private var settings: ClipmanSettings!
    private var store: ClipStore!
    private var fileStore: FileHistoryStore!
    private var secretStore: SecretStore!
    private var statusItem: NSStatusItem!
    private var historyWindow: HistoryWindowController!
    private var preferencesWindow: PreferencesWindowController?
    private var secretsWindow: SecretsWindowController?
    private weak var previousFrontmostApplication: NSRunningApplication?
    private var sessionDatabasePassword = ""
    private var sessionPasswordDatabasePath = ""
    private var cancelledPasswordPaths = Set<String>()
    private var remoteClipboardBaseline: (id: String, stamp: Int64)?
    private var updateTimer: Timer?
    private var serverRecoveryTimer: Timer?
    private var storageUnavailableReasons: [String: String] = [:]
    private var serverSyncWarning = ""
    private var monitoringPausedForStorage = false
    private var databaseErrorAlertShown = false
    private var databasePasswordRecoveryInProgress = false

    private var storageUnavailableReason: String {
        storageUnavailableReasons.values.sorted().joined(separator: "; ")
    }

    private var statusWarningReason: String {
        ([storageUnavailableReason, serverSyncWarning].filter { !$0.isEmpty }).joined(separator: "; ")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard enforceSingleRunningInstance() else {
            NSApp.terminate(nil)
            return
        }

        settings = settingsStore.load()
        migrateServerTokenToKeychainIfNeeded()
        settings.serverToken = currentServerToken(for: settings)
        sounds.useDataFolder(settingsStore.dataFolder(for: settings))
        migrateLegacyKeychainPasswordIfNeeded()
        let initialPassword = initialDatabasePassword()
        seedServerCacheFromConfiguredDatabase()
        store = ClipStore(databaseURL: textHistoryURL(for: settings), machineName: settings.machineName)
        store.delegate = self
        store.setDatabaseURL(textHistoryURL(for: settings), password: initialPassword)
        configureTextHistoryServerStorage()
        fileStore = FileHistoryStore(databaseURL: fileHistoryURL(for: settings), machineName: settings.machineName, password: initialPassword)
        fileStore.delegate = self
        fileStore.load()
        secretStore = SecretStore(databaseURL: secretsURL(for: settings), passwordProvider: { [weak self] in
            self?.currentDatabasePassword(for: self?.settings.databasePath ?? "") ?? ""
        })

        historyWindow = HistoryWindowController()
        historyWindow.historyDelegate = self
        historyWindow.configureSort(
            textSortMode: settings.sortMode,
            textDescending: settings.sortDescending,
            fileSortMode: settings.fileHistorySortMode,
            fileDescending: settings.fileHistorySortDescending,
            selectedTab: settings.lastSelectedTab,
            selectedHistoryTab: settings.lastSelectedHistoryTab,
            linksHistoryEnabled: settings.linksHistoryEnabled,
            groupFilter: settings.groupFilter
        )
        configureHistoryQuickCopyState()
        sounds.isEnabled = settings.soundsEnabled
        monitor.delegate = self
        monitor.isEnabled = settings.monitoringEnabled
        monitor.ignoredApplications = settings.ignoredApplications
        monitor.start()
        if settings.captureClipboardOnStartup {
            monitor.captureCurrentContents()
        }
        sounds.play(settings.monitoringEnabled ? .on : .off)
        applyStartupRegistration(showErrors: false)

        buildStatusItem()
        hotkeys.handler = { [weak self] action in
            switch action {
            case .showHistory: self?.toggleHistoryFromHotkey()
            case .toggleMonitoring: self?.toggleMonitoring(nil)
            case .quickCopy(let entryID): self?.quickPasteEntry(id: entryID)
            case .secret(let entryID): self?.quickPasteSecret(id: entryID)
            }
        }
        registerHotkeys()
        NSApp.setActivationPolicy(.accessory)
        buildMainMenu()
        scheduleUpdateChecks()
        scheduleServerRecoveryChecks()
    }

    private func enforceSingleRunningInstance() -> Bool {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.andrelouis.clipman"
        let otherInstances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { $0.processIdentifier != currentPID && !$0.isTerminated }
        guard let existing = otherInstances.first else {
            return true
        }

        let alert = NSAlert()
        alert.messageText = "Clipman is already running"
        alert.informativeText = "Another copy of Clipman is already running. Running two copies at the same time can cause duplicate clipboard monitoring and database conflicts. Quit the existing copy and continue with this one?"
        alert.addButton(withTitle: "Quit Existing and Continue")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            return false
        }

        existing.terminate()
        let deadline = Date().addingTimeInterval(5)
        while !existing.isTerminated && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        if existing.isTerminated {
            return true
        }

        let failedAlert = NSAlert()
        failedAlert.messageText = "Could Not Quit Existing Clipman"
        failedAlert.informativeText = "The existing Clipman copy did not close. This copy will quit so two clipboard monitors do not run at the same time."
        failedAlert.addButton(withTitle: "OK")
        failedAlert.runModal()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
        hotkeys.unregisterAll()
        updateTimer?.invalidate()
        serverRecoveryTimer?.invalidate()
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusItem()
        rebuildMenu()
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let title = settings.monitoringEnabled ? "Clipman: On" : "Clipman: Off"
        button.title = title
        button.setAccessibilityLabel(title)
        button.toolTip = statusWarningReason.isEmpty ? title : "Clipman: \(statusWarningReason)"
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu(title: "Clipman")
        let appMenuItem = NSMenuItem(title: "Clipman", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "Clipman")
        appMenu.addItem(NSMenuItem(title: "Show History", action: #selector(showHistory(_:)), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem(title: "Show File History", action: #selector(showFileHistory(_:)), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem(title: "Toggle Monitoring", action: #selector(toggleMonitoring(_:)), keyEquivalent: ""))
        let appSecretsItem = NSMenuItem(title: "Secrets...", action: #selector(showSecrets(_:)), keyEquivalent: "e")
        appSecretsItem.keyEquivalentModifierMask = [.command, .shift]
        appMenu.addItem(appSecretsItem)
        appMenu.addItem(NSMenuItem(title: "Open Manual", action: #selector(openManual(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates(_:)), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem(title: "Version History...", action: #selector(openVersionHistory(_:)), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem(title: "Project Page", action: #selector(openProjectPage(_:)), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem(title: "Contact", action: #selector(openContactPage(_:)), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem(title: "Donate", action: #selector(openDonatePage(_:)), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem(title: "Diagnostics...", action: #selector(showDiagnostics(_:)), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem(title: "Open Settings Folder", action: #selector(openSettingsFolder(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Preferences...", action: #selector(showPreferences(_:)), keyEquivalent: ","))
        appMenu.addItem(NSMenuItem(title: "About Clipman", action: #selector(showAbout(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Clipman", action: #selector(quit(_:)), keyEquivalent: "q"))
        for item in appMenu.items {
            item.target = self
        }
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        NSApp.mainMenu = mainMenu
    }

    private func rebuildMenu() {
        guard statusItem != nil else { return }
        let menu = NSMenu(title: "Clipman")
        if !storageUnavailableReason.isEmpty {
            let item = NSMenuItem(title: "Storage unavailable", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(NSMenuItem(title: "Retry Storage", action: #selector(retryStorage(_:)), keyEquivalent: ""))
            menu.addItem(.separator())
        } else if !serverSyncWarning.isEmpty {
            let item = NSMenuItem(title: "Server sync unavailable", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(NSMenuItem(title: "Retry Server Sync", action: #selector(retryStorage(_:)), keyEquivalent: ""))
            menu.addItem(.separator())
        }
        menu.addItem(NSMenuItem(title: "Show History", action: #selector(showHistory(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Show File History", action: #selector(showFileHistory(_:)), keyEquivalent: ""))
        let monitorTitle = storageUnavailableReason.isEmpty
            ? (settings.monitoringEnabled ? "Turn Monitoring Off" : "Turn Monitoring On")
            : "Monitoring Paused Until Storage Returns"
        menu.addItem(NSMenuItem(title: monitorTitle, action: #selector(toggleMonitoring(_:)), keyEquivalent: ""))
        let statusSecretsItem = NSMenuItem(title: "Secrets...", action: #selector(showSecrets(_:)), keyEquivalent: "e")
        statusSecretsItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(statusSecretsItem)
        menu.addItem(NSMenuItem(title: "Open Manual", action: #selector(openManual(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Version History...", action: #selector(openVersionHistory(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Project Page", action: #selector(openProjectPage(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Contact", action: #selector(openContactPage(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Donate", action: #selector(openDonatePage(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Diagnostics...", action: #selector(showDiagnostics(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open Settings Folder", action: #selector(openSettingsFolder(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Preferences...", action: #selector(showPreferences(_:)), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "About Clipman", action: #selector(showAbout(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Clipman", action: #selector(quit(_:)), keyEquivalent: "q"))
        for item in menu.items {
            item.target = self
        }
        statusItem.menu = menu
    }

    @objc private func showHistory(_ sender: Any?) {
        rememberPreviousFrontmostApplication()
        refreshHistoryWindow()
        historyWindow.showWindow(nil)
        historyWindow.focusHistoryWindow(nil)
    }

    private func toggleHistoryFromHotkey() {
        if historyWindow.isHistoryVisible {
            historyWindow.hide()
            return
        }
        showHistory(nil)
    }

    @objc private func showFileHistory(_ sender: Any?) {
        showHistory(sender)
        historyWindow.showFileHistory()
    }

    @objc private func showSecrets(_ sender: Any?) {
        let currentPassword = currentDatabasePassword(for: settings.databasePath)
        guard !currentPassword.isEmpty else {
            showInformationalAlert(
                title: "Clipman Secrets",
                message: "Secrets require a history password. Open Preferences, set a history password, and remember it in Keychain if you want secrets available after restart."
            )
            return
        }
        guard confirmSecretsPassword(currentPassword: currentPassword) else { return }
        if secretsWindow == nil {
            secretsWindow = SecretsWindowController(store: secretStore)
            secretsWindow?.secretsDelegate = self
        }
        secretsWindow?.showWindow(sender)
    }

    private func confirmSecretsPassword(currentPassword: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Unlock Clipman Secrets"
        alert.informativeText = "Enter the current history password to open Secrets."
        alert.addButton(withTitle: "Unlock")
        alert.addButton(withTitle: "Cancel")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.setAccessibilityLabel("Current history password")
        alert.accessoryView = field
        guard runModalWithTextEditingShortcuts(alert) == .alertFirstButtonReturn else { return false }
        if field.stringValue == currentPassword {
            return true
        }
        showInformationalAlert(title: "Clipman Secrets", message: "The history password did not match. Secrets were not opened.")
        return false
    }

    private func runModalWithTextEditingShortcuts(_ alert: NSAlert) -> NSApplication.ModalResponse {
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard modifiers == [.command],
                  let command = event.charactersIgnoringModifiers?.lowercased() else {
                return event
            }
            switch command {
            case "a":
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                return nil
            case "x":
                NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
                return nil
            case "c":
                NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                return nil
            case "v":
                NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                return nil
            default:
                return event
            }
        }
        defer {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
        return alert.runModal()
    }

    @objc private func toggleMonitoring(_ sender: Any?) {
        guard storageUnavailableReason.isEmpty else {
            retryStorage(sender)
            return
        }
        settings.monitoringEnabled.toggle()
        monitor.isEnabled = settings.monitoringEnabled
        try? settingsStore.save(settings)
        sounds.play(settings.monitoringEnabled ? .on : .off)
        updateStatusItem()
        rebuildMenu()
    }

    private func quickPasteEntry(id: String) {
        guard let entry = store.entry(id: id) else {
            NSSound.beep()
            return
        }
        let mode = QuickPasteMode.normalize(settings.quickPasteModes[id])
        let text = TemplateResolver.resolveEntryText(entry)
        switch mode {
        case .pasteRestore:
            monitor.writeTemporaryInternalText(text, restoreAfter: 0.35) {
                self.sendPasteKeystroke()
            }
        case .pasteKeep:
            monitor.writeInternalText(text)
            sendPasteKeystroke()
        case .copyOnly:
            monitor.writeInternalText(text)
        }
        sounds.play(.copy)
        store.markUsed(entry.Id)
    }

    private func quickPasteSecret(id: String) {
        guard let secret = secretStore.entry(id: id) else {
            NSSound.beep()
            return
        }
        quickPaste(secret: secret)
    }

    private func quickPaste(secret: SecretEntry) {
        guard !secret.Value.isEmpty else {
            NSSound.beep()
            return
        }
        monitor.writeTemporaryInternalText(secret.Value, restoreAfter: 0.35) {
            self.sendPasteKeystroke()
        }
        sounds.play(.copy)
    }

    private func sendPasteKeystroke() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    @objc private func openManual(_ sender: Any?) {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("Manual.html")
        if let bundled, FileManager.default.fileExists(atPath: bundled.path) {
            NSWorkspace.shared.open(bundled)
        } else {
            let alert = NSAlert()
            alert.messageText = "Clipman Manual Not Found"
            alert.informativeText = "Manual.html was not found in the app bundle."
            alert.runModal()
        }
    }

    private func formatDiagnosticTime(_ unixMs: Int64) -> String {
        guard unixMs > 0 else { return "Never" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(unixMs) / 1000.0))
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        runUpdateCheck(manual: true)
    }

    @objc private func openVersionHistory(_ sender: Any?) {
        updates.openVersionHistory()
    }

    @objc private func openProjectPage(_ sender: Any?) {
        if let url = URL(string: "https://github.com/OnjLouis/Clipman") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openContactPage(_ sender: Any?) {
        if let url = URL(string: "https://onj.me/contact") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openDonatePage(_ sender: Any?) {
        if let url = URL(string: "https://onj.me/donate") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func showDiagnostics(_ sender: Any?) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let buildStamp = Bundle.main.object(forInfoDictionaryKey: "ClipmanBuildStampUtcMs") as? String ?? "unknown"
        let dataFolder = URL(fileURLWithPath: settings.databasePath).deletingLastPathComponent().path
        let serverStatus = store.serverSyncStatus()
        let report = [
            "Clipman diagnostics",
            "",
            "Version: \(version)",
            "Build: \(build)",
            "Build stamp: \(buildStamp)",
            "Machine: \(settings.machineName)",
            "Monitoring: \(settings.monitoringEnabled ? "On" : "Off")",
            "Data folder: \(dataFolder)",
            "Storage mode: \(settings.storageMode)",
            "Server host: \(settings.serverUrl.isEmpty ? "not set" : settings.serverUrl)",
            "Server sync enabled: \(serverStatus.enabled)",
            "Server sync configured: \(serverStatus.configured)",
            "Server sync revision: \(serverStatus.revision.isEmpty ? "None" : serverStatus.revision)",
            "Server sync last poll: \(formatDiagnosticTime(serverStatus.lastPollUnixMs))",
            "Server sync last success: \(formatDiagnosticTime(serverStatus.lastSuccessUnixMs))",
            "Server sync last upload: \(formatDiagnosticTime(serverStatus.lastUploadUnixMs))",
            "Server sync next retry: \(formatDiagnosticTime(serverStatus.nextPollUnixMs))",
            "Server sync consecutive failures: \(serverStatus.consecutiveFailures)",
            "Text history: \(settings.databasePath)",
            "Local text cache: \(textHistoryURL(for: settings).path)",
            "Text entries: \(store.entryCount())",
            "File history: \(fileHistoryURL(for: settings).path)",
            "File events: \(fileStore.eventCount())",
            "Secrets: \(secretStore.entries().count) configured",
            "Runtime crash log: \(RuntimeLogger.logURL.path)",
            "Text sort: \(settings.sortMode), \(settings.sortDescending ? "descending" : "ascending")",
            "File sort: \(settings.fileHistorySortMode), \(settings.fileHistorySortDescending ? "descending" : "ascending")",
            "Group filter: \(settings.groupFilter)",
            "Remember password: \(settings.rememberDatabasePassword ? "On" : "Off")",
            "Run at login: \(settings.runAtStartup ? "On" : "Off")",
            "Add clipboard item on startup: \(settings.captureClipboardOnStartup ? "On" : "Off")",
            "Auto-copy latest remote text: \(settings.autoCopyLatestRemoteText ? "On" : "Off")",
            "Update checks: \(settings.updateCheckFrequency)",
            "Ignored applications: \(settings.ignoredApplications.isEmpty ? "None" : settings.ignoredApplications.joined(separator: ", "))",
            "",
            monitor.diagnosticsReport()
        ].joined(separator: "\n")

        let alert = NSAlert()
        alert.messageText = "Clipman Diagnostics"
        alert.addButton(withTitle: "Close")
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 620, height: 320))
        textView.string = report
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.setAccessibilityLabel("Clipman diagnostics report")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 620, height: 320))
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.documentView = textView
        alert.accessoryView = scroll
        alert.runModal()
    }

    @objc private func showPreferences(_ sender: Any?) {
        if preferencesWindow == nil {
            preferencesWindow = PreferencesWindowController(
                settings: settings,
                historyIsEncrypted: encryptedHistoryExists(for: settings),
                rememberedPasswordExists: keychain.hasPassword(for: settings.databasePath)
            )
            preferencesWindow?.preferencesDelegate = self
        } else {
            preferencesWindow?.update(
                settings: settings,
                historyIsEncrypted: encryptedHistoryExists(for: settings),
                rememberedPasswordExists: keychain.hasPassword(for: settings.databasePath)
            )
        }
        preferencesWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openSettingsFolder(_ sender: Any?) {
        let folder = settingsStore.dataFolder(for: settings)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    @objc private func showAbout(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Clipman"
        alert.informativeText = "Native macOS clipboard history for shared Clipman text databases."
        alert.runModal()
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    func clipboardMonitor(_ monitor: ClipboardMonitor, didCapture text: String, sourceApplication: String) {
        guard storageUnavailableReason.isEmpty else {
            sounds.play(.skip)
            return
        }
        if store.hasRecentlyTouchedRemoteText(text, excluding: settings.machineName) {
            return
        }
        if SensitiveDataExclusion.matchName(in: text, mode: settings.sensitiveDataMode, presetIds: settings.sensitiveDataPresetIds) != nil {
            sounds.play(.exclude)
            return
        }
        store.addText(text, group: sourceApplication) { [weak self] saved in
            guard let self else { return }
            if saved {
                self.sounds.play(.copy)
            } else if self.storageUnavailableReason.isEmpty {
                self.sounds.play(.skip)
            }
        }
    }

    func clipboardMonitor(_ monitor: ClipboardMonitor, didCaptureFiles files: [String], formats: [String], containsText: Bool) {
        guard storageUnavailableReason.isEmpty else {
            sounds.play(.skip)
            return
        }
        fileStore.add(files: files, formats: formats, containsText: containsText) { [weak self] saved in
            guard let self else { return }
            if saved {
                self.sounds.play(.copy)
            } else if self.storageUnavailableReason.isEmpty {
                self.sounds.play(.skip)
            }
        }
    }

    func clipboardMonitorDidSkipIgnoredApplication(_ monitor: ClipboardMonitor) {
        sounds.play(.skip)
    }

    func clipStoreDidChange() {
        databaseErrorAlertShown = false
        clearServerSyncWarningIfNeeded()
        clearStorageFailureIfNeeded(area: "text history")
        historyWindow.update(entries: sortedTextEntries())
        copyLatestRemoteTextIfNeeded()
    }

    func fileHistoryStoreDidChange() {
        clearStorageFailureIfNeeded(area: "file history")
        historyWindow.update(fileEvents: sortedFileEvents())
    }

    func fileHistoryStoreDidFail(error: Error) {
        RuntimeLogger.write("File history store failed.", error: error, details: "Area: file history")
        if isDatabasePasswordError(error) {
            recoverHistoryPassword(after: error, area: "file history")
            return
        }
        handleStorageFailure(error: error, area: "file history")
    }

    func clipStoreNeedsPassword(for path: String) -> String? {
        let identityPath = databasePasswordIdentityPath(for: path)
        if let password = sessionPassword(for: identityPath), !password.isEmpty {
            return password
        }
        guard !cancelledPasswordPaths.contains(identityPath) else { return nil }
        guard let password = promptForDatabasePassword(path: identityPath) else {
            cancelledPasswordPaths.insert(identityPath)
            return nil
        }
        applyDatabasePassword(password, for: identityPath)
        return password
    }

    private func promptForDatabasePassword(path: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "History Password Required"
        alert.informativeText = "Enter the password for \(path)."
        alert.addButton(withTitle: "Unlock")
        alert.addButton(withTitle: "Cancel")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.setAccessibilityLabel("History password")
        alert.accessoryView = field
        let result = alert.runModal()
        guard result == .alertFirstButtonReturn else { return nil }
        let password = field.stringValue
        return password.isEmpty ? nil : password
    }

    func clipStoreDidFail(error: Error) {
        RuntimeLogger.write("Text history store failed.", error: error, details: "Area: text history")
        if isDatabasePasswordError(error) {
            recoverHistoryPassword(after: error, area: "text history")
            return
        }
        if isServerSyncError(error) {
            handleServerSyncFailure(error)
            return
        }
        if isRecoverableStorageError(error) {
            handleStorageFailure(error: error, area: "text history")
            return
        }
        guard !databaseErrorAlertShown else { return }
        databaseErrorAlertShown = true
        let alert = NSAlert(error: error)
        alert.messageText = "Clipman Database Error"
        alert.runModal()
    }

    @objc private func retryStorage(_ sender: Any?) {
        clearServerSyncWarningIfNeeded()
        seedServerCacheFromConfiguredDatabase()
        let password = currentDatabasePassword(for: settings.databasePath)
        store.setDatabaseURL(textHistoryURL(for: settings), password: password)
        configureTextHistoryServerStorage()
        store.load()
        fileStore.load()
    }

    private func handleStorageFailure(error: Error, area: String) {
        guard isRecoverableStorageError(error) else {
            let alert = NSAlert(error: error)
            alert.messageText = area == "file history" ? "Clipman File History Error" : "Clipman Database Error"
            alert.runModal()
            return
        }

        markStorageUnavailable(area: area, message: "\(area) storage is unavailable: \(error.localizedDescription)")
    }

    private func markStorageUnavailable(area: String, message: String) {
        let wasAvailable = storageUnavailableReason.isEmpty
        storageUnavailableReasons[area] = message
        if settings.monitoringEnabled && monitor.isEnabled {
            monitor.isEnabled = false
            monitoringPausedForStorage = true
        }
        updateStatusItem()
        rebuildMenu()
        if wasAvailable {
            sounds.play(.skip)
        }
    }

    private func handleServerSyncFailure(_ error: Error) {
        let message = "Server sync is unavailable: \(error.localizedDescription)"
        let wasEmpty = serverSyncWarning.isEmpty
        serverSyncWarning = message
        updateStatusItem()
        rebuildMenu()
        if wasEmpty && storageUnavailableReason.isEmpty {
            sounds.play(.skip)
        }
    }

    private func clearServerSyncWarningIfNeeded() {
        guard !serverSyncWarning.isEmpty else { return }
        serverSyncWarning = ""
        updateStatusItem()
        rebuildMenu()
    }

    private func recoverHistoryPassword(after _: Error, area: String) {
        guard !databasePasswordRecoveryInProgress else { return }
        databasePasswordRecoveryInProgress = true
        defer { databasePasswordRecoveryInProgress = false }

        let identityPath = databasePasswordIdentityPath(for: settings.databasePath)
        sessionDatabasePassword = ""
        sessionPasswordDatabasePath = ""
        guard let password = promptForDatabasePassword(path: identityPath) else {
            cancelledPasswordPaths.insert(identityPath)
            markStorageUnavailable(area: area, message: "\(area) is locked because the history password was not supplied.")
            return
        }

        applyDatabasePassword(password, for: identityPath)
        databaseErrorAlertShown = false
        clearStorageFailureIfNeeded(area: area)
        store.setDatabaseURL(textHistoryURL(for: settings), password: password)
        configureTextHistoryServerStorage()
        store.load()
        fileStore.load()
    }

    private func clearStorageFailureIfNeeded(area: String) {
        guard !storageUnavailableReason.isEmpty else { return }
        storageUnavailableReasons.removeValue(forKey: area)
        guard storageUnavailableReason.isEmpty else {
            updateStatusItem()
            rebuildMenu()
            return
        }
        updateStatusItem()
        if monitoringPausedForStorage {
            monitoringPausedForStorage = false
            monitor.isEnabled = settings.monitoringEnabled
        }
        rebuildMenu()
    }

    private func isRecoverableStorageError(_ error: Error) -> Bool {
        if let databaseError = error as? ClipDatabaseError {
            switch databaseError {
            case .passwordRequired, .incorrectPassword:
                return false
            default:
                return true
            }
        }
        if error is ServerStorageError {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain || nsError.domain == NSPOSIXErrorDomain
    }

    private func isServerSyncError(_ error: Error) -> Bool {
        if error is ServerSyncFailureError {
            return true
        }
        if error is ServerStorageError {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
    }

    private func isDatabasePasswordError(_ error: Error) -> Bool {
        guard let databaseError = error as? ClipDatabaseError else { return false }
        switch databaseError {
        case .passwordRequired, .incorrectPassword:
            return true
        default:
            return false
        }
    }

    func historyWindow(_ controller: HistoryWindowController, didChoose entry: ClipEntry) {
        monitor.writeInternalText(TemplateResolver.resolveEntryText(entry))
        sounds.play(.copy)
        store.markUsed(entry.Id)
        controller.hide()
    }

    func historyWindow(_ controller: HistoryWindowController, didTogglePin entry: ClipEntry) {
        store.togglePinned(entry.Id)
    }

    func historyWindow(_ controller: HistoryWindowController, didDelete entry: ClipEntry) {
        store.delete(entry.Id)
    }

    func historyWindow(_ controller: HistoryWindowController, didEdit entry: ClipEntry, name: String, text: String) {
        store.setNameAndText(id: entry.Id, name: name, text: text)
    }

    func historyWindow(_ controller: HistoryWindowController, didUpdateProperties entry: ClipEntry, name: String, group: String, text: String, isTemplate: Bool, useQuickCopy: Bool, quickCopyHotkey: HotkeyDescriptor?, quickPasteMode: QuickPasteMode) {
        store.setNameAndText(id: entry.Id, name: name, text: text)
        store.setGroup(ids: [entry.Id], group: group)
        store.setTemplate(id: entry.Id, isTemplate: isTemplate)
        if useQuickCopy {
            if let quickCopyHotkey {
                settings.quickCopyHotkeys[entry.Id] = quickCopyHotkey
                settings.quickPasteModes[entry.Id] = quickPasteMode.rawValue
            }
        } else {
            settings.quickCopyHotkeys.removeValue(forKey: entry.Id)
            settings.quickPasteModes.removeValue(forKey: entry.Id)
        }
        try? settingsStore.save(settings)
        configureHistoryQuickCopyState()
        registerHotkeys()
        sounds.play(.copy)
    }

    func historyWindow(_ controller: HistoryWindowController, didCopy entries: [ClipEntry]) {
        let text = entries.map(TemplateResolver.resolveEntryText).joined(separator: "\n---\n")
        monitor.writeInternalText(text)
        sounds.play(.copy)
    }

    func historyWindow(_ controller: HistoryWindowController, didCut entries: [ClipEntry]) {
        historyWindow(controller, didCopy: entries)
        for entry in entries where !entry.Pinned {
            store.delete(entry.Id)
        }
    }

    func historyWindow(_ controller: HistoryWindowController, didPushToOtherMachines entries: [ClipEntry]) {
        store.pushEntriesToOtherMachines(ids: entries.map(\.Id))
        sounds.play(.copy)
    }

    func historyWindow(_ controller: HistoryWindowController, didMove entries: [ClipEntry], direction: Int) {
        settings.sortMode = "Manual"
        settings.sortDescending = false
        try? settingsStore.save(settings)
        historyWindow.configureSort(
            textSortMode: settings.sortMode,
            textDescending: settings.sortDescending,
            fileSortMode: settings.fileHistorySortMode,
            fileDescending: settings.fileHistorySortDescending,
            selectedTab: settings.lastSelectedTab,
            selectedHistoryTab: settings.lastSelectedHistoryTab,
            linksHistoryEnabled: settings.linksHistoryEnabled,
            groupFilter: settings.groupFilter
        )
        store.moveEntries(ids: entries.map(\.Id), direction: direction)
    }

    func historyWindowDidRequestPaste(_ controller: HistoryWindowController, after entry: ClipEntry?) {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            NSSound.beep()
            return
        }
        let pasted = text
            .components(separatedBy: "\n---\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { ClipEntry(Text: $0, SourceMachine: settings.machineName) }
        store.insertTextsAfterSelected(pasted, afterID: entry?.Id)
    }

    func historyWindowDidRequestImport(_ controller: HistoryWindowController) {
        let panel = NSOpenPanel()
        panel.title = "Import Clipboard Entries"
        panel.prompt = "Import"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = supportedImportExportTypes()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importEntries(from: url, importPassword: nil)
    }

    private func importEntries(from url: URL, importPassword: String?) {
        store.importEntries(from: url, importPassword: importPassword) { [weak self] result in
            Task { @MainActor in
                switch result {
                case .success(let count):
                    self?.showInformationalAlert(
                        title: "Import Complete",
                        message: count == 1 ? "Imported one clipboard entry." : "Imported \(count) clipboard entries."
                    )
                case .failure(let error):
                    guard self?.isImportPasswordError(error) == true else { return }
                    guard let password = self?.promptForImportPassword(path: url.path) else { return }
                    self?.importEntries(from: url, importPassword: password)
                }
            }
        }
    }

    private func promptForImportPassword(path: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Import Password Required"
        alert.informativeText = "The selected Clipman import file is encrypted. Enter its history password."
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.setAccessibilityLabel("Import file history password")
        alert.accessoryView = field
        let result = alert.runModal()
        guard result == .alertFirstButtonReturn else { return nil }
        let password = field.stringValue
        return password.isEmpty ? nil : password
    }

    private func isImportPasswordError(_ error: Error) -> Bool {
        guard let databaseError = error as? ClipDatabaseError else { return false }
        switch databaseError {
        case .passwordRequired, .incorrectPassword:
            return true
        default:
            return false
        }
    }

    func historyWindowDidRequestExport(_ controller: HistoryWindowController) {
        let panel = NSSavePanel()
        panel.title = "Export Clipboard Entries"
        panel.prompt = "Export"
        panel.nameFieldStringValue = "clipman-export"
        panel.allowedContentTypes = supportedImportExportTypes()
        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
        let url = removingDuplicatePathExtension(from: selectedURL)
        guard let passwordChoice = chooseExportPassword(for: url) else { return }
        let exportPassword: String?
        switch passwordChoice {
        case .current:
            exportPassword = nil
        case .password(let password):
            exportPassword = password
        case .none:
            exportPassword = ""
        }
        store.exportDatabase(to: url, exportPassword: exportPassword) { [weak self] result in
            Task { @MainActor in
                switch result {
                case .success:
                    self?.showInformationalAlert(title: "Export Complete", message: "Exported clipboard entries.")
                case .failure:
                    break
                }
            }
        }
    }

    private func removingDuplicatePathExtension(from url: URL) -> URL {
        let fileName = url.lastPathComponent
        let pathExtension = url.pathExtension
        guard !pathExtension.isEmpty else { return url }
        let duplicatedSuffix = ".\(pathExtension).\(pathExtension)"
        guard fileName.lowercased().hasSuffix(duplicatedSuffix.lowercased()) else { return url }
        return url.deletingPathExtension()
    }

    private func chooseExportPassword(for url: URL) -> ExportPasswordChoice? {
        guard url.pathExtension.caseInsensitiveCompare("clipdb") == .orderedSame else {
            return ExportPasswordChoice.none
        }

        while true {
            let currentPasswordAvailable = !store.currentPassword().isEmpty
            let alert = NSAlert()
            alert.messageText = "Export Password"
            alert.informativeText = "Choose how to protect this .clipdb export."
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Cancel")

            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26), pullsDown: false)
            if currentPasswordAvailable {
                popup.addItem(withTitle: "Use current history password")
            }
            popup.addItem(withTitle: "Use a new export password")
            popup.addItem(withTitle: "Use no password")
            popup.setAccessibilityLabel("Export password choice")
            alert.accessoryView = popup

            guard alert.runModal() == .alertFirstButtonReturn else { return nil }

            let selection = popup.titleOfSelectedItem ?? ""
            if selection == "Use current history password" {
                guard confirmCurrentExportPassword() else { continue }
                return .current
            }
            if selection == "Use no password" {
                if currentPasswordAvailable {
                    guard confirmCurrentExportPassword() else { continue }
                }
                return ExportPasswordChoice.none
            }
            guard let password = promptForNewExportPassword() else { continue }
            if currentPasswordAvailable {
                guard confirmCurrentExportPassword() else { continue }
            }
            return .password(password)
        }
    }

    private func confirmCurrentExportPassword() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Confirm History Password"
        alert.informativeText = "Enter the current history password to create this export."
        alert.addButton(withTitle: "Export")
        alert.addButton(withTitle: "Cancel")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.setAccessibilityLabel("Current history password")
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        if field.stringValue == store.currentPassword() {
            return true
        }
        showInformationalAlert(title: "Export Password", message: "The current history password did not match. The export was not created.")
        return false
    }

    private func promptForNewExportPassword() -> String? {
        let alert = NSAlert()
        alert.messageText = "New Export Password"
        alert.informativeText = "Enter and confirm the password for this export file."
        alert.addButton(withTitle: "Export")
        alert.addButton(withTitle: "Cancel")

        let passwordField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        passwordField.placeholderString = "New export password"
        passwordField.setAccessibilityLabel("New export password")
        let confirmField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        confirmField.placeholderString = "Confirm new export password"
        confirmField.setAccessibilityLabel("Confirm new export password")
        let stack = NSStackView(views: [passwordField, confirmField])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: 56)
        alert.accessoryView = stack

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let password = passwordField.stringValue
        if password.isEmpty {
            showInformationalAlert(title: "Export Password", message: "Enter an export password, or choose Use no password.")
            return nil
        }
        if password != confirmField.stringValue {
            showInformationalAlert(title: "Export Password", message: "The export password and confirmation do not match.")
            return nil
        }
        return password
    }

    func historyWindow(_ controller: HistoryWindowController, didCleanURLTracking entries: [ClipEntry]) {
        transformSelectedEntries(entries, transform: URLTrackingCleaner.cleanText(_:))
    }

    func historyWindow(_ controller: HistoryWindowController, didCleanLinksForSharing entries: [ClipEntry]) {
        transformSelectedEntries(entries, transform: URLTrackingCleaner.cleanForSharing(_:))
    }

    func historyWindow(_ controller: HistoryWindowController, didNormalizeLineEndings entries: [ClipEntry], style: LineEndingStyle) {
        transformSelectedEntries(entries) { text in
            LineEndingNormalizer.normalize(text, to: style)
        }
    }

    func historyWindow(_ controller: HistoryWindowController, didSetGroup group: String, for entries: [ClipEntry]) {
        store.setGroup(ids: entries.map(\.Id), group: group)
    }

    func historyWindow(_ controller: HistoryWindowController, didChooseFileEvent event: FileClipboardEvent) {
        let existing = event.Files.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else {
            NSSound.beep()
            return
        }
        monitor.writeInternalFiles(existing)
        sounds.play(.copy)
        controller.hide()
    }

    func historyWindow(_ controller: HistoryWindowController, didTogglePinFileEvent event: FileClipboardEvent) {
        fileStore.togglePinned(event.Id)
    }

    func historyWindow(_ controller: HistoryWindowController, didDeleteFileEvent event: FileClipboardEvent) {
        fileStore.delete(event.Id)
    }

    func historyWindow(_ controller: HistoryWindowController, didCopyFilePaths events: [FileClipboardEvent]) {
        let paths = events.flatMap(\.Files)
        guard !paths.isEmpty else {
            NSSound.beep()
            return
        }
        monitor.writeInternalText(paths.joined(separator: "\n"))
        sounds.play(.copy)
    }

    func historyWindow(_ controller: HistoryWindowController, didRequestGoToFileEvent event: FileClipboardEvent) {
        guard event.Files.count == 1,
              let path = event.Files.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else {
            NSSound.beep()
            showInformationalAlert(title: "Go To File", message: "Select one file-history event containing exactly one file or folder.")
            return
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            NSSound.beep()
            showInformationalAlert(title: "Go To File", message: "That file or folder no longer exists.")
            return
        }

        let url = URL(fileURLWithPath: path)
        if isDirectory.boolValue {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func historyWindow(_ controller: HistoryWindowController, didMoveFileEvents events: [FileClipboardEvent], direction: Int) {
        settings.fileHistorySortMode = "Manual"
        settings.fileHistorySortDescending = false
        try? settingsStore.save(settings)
        historyWindow.configureSort(
            textSortMode: settings.sortMode,
            textDescending: settings.sortDescending,
            fileSortMode: settings.fileHistorySortMode,
            fileDescending: settings.fileHistorySortDescending,
            selectedTab: settings.lastSelectedTab,
            selectedHistoryTab: settings.lastSelectedHistoryTab,
            linksHistoryEnabled: settings.linksHistoryEnabled,
            groupFilter: settings.groupFilter
        )
        fileStore.moveEvents(ids: events.map(\.Id), direction: direction)
    }

    func historyWindowDidRequestClearNormalFileHistory(_ controller: HistoryWindowController) {
        fileStore.clearNormal()
    }

    func historyWindowDidRequestRemoveUnavailableFileHistory(_ controller: HistoryWindowController) {
        fileStore.removeUnavailable()
    }

    func historyWindow(_ controller: HistoryWindowController, didChangeHistoryTab tab: String) {
        settings.lastSelectedHistoryTab = HistoryTabID.normalize(tab, linksEnabled: settings.linksHistoryEnabled)
        settings.lastSelectedTab = settings.lastSelectedHistoryTab == HistoryTabID.files ? 1 : 0
        try? settingsStore.save(settings)
        refreshHistoryWindow()
    }

    func historyWindow(_ controller: HistoryWindowController, didChangeSortMode sortMode: String, fileHistory: Bool) {
        if fileHistory {
            settings.fileHistorySortMode = sortMode
            settings.fileHistorySortDescending = defaultFileSortDescending(sortMode)
        } else {
            settings.sortMode = sortMode
            settings.sortDescending = defaultTextSortDescending(sortMode)
        }
        try? settingsStore.save(settings)
        historyWindow.configureSort(
            textSortMode: settings.sortMode,
            textDescending: settings.sortDescending,
            fileSortMode: settings.fileHistorySortMode,
            fileDescending: settings.fileHistorySortDescending,
            selectedTab: settings.lastSelectedTab,
            selectedHistoryTab: settings.lastSelectedHistoryTab,
            linksHistoryEnabled: settings.linksHistoryEnabled,
            groupFilter: settings.groupFilter
        )
        refreshHistoryWindow()
    }

    func historyWindowDidToggleSortDirection(_ controller: HistoryWindowController, fileHistory: Bool) {
        if fileHistory {
            settings.fileHistorySortDescending.toggle()
        } else {
            settings.sortDescending.toggle()
        }
        try? settingsStore.save(settings)
        historyWindow.configureSort(
            textSortMode: settings.sortMode,
            textDescending: settings.sortDescending,
            fileSortMode: settings.fileHistorySortMode,
            fileDescending: settings.fileHistorySortDescending,
            selectedTab: settings.lastSelectedTab,
            selectedHistoryTab: settings.lastSelectedHistoryTab,
            linksHistoryEnabled: settings.linksHistoryEnabled,
            groupFilter: settings.groupFilter
        )
        refreshHistoryWindow()
    }

    func historyWindow(_ controller: HistoryWindowController, didChangeGroupFilter groupFilter: String) {
        settings.groupFilter = groupFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "All" : groupFilter
        try? settingsStore.save(settings)
        refreshHistoryWindow()
    }

    func historyWindowDidRequestPreferences(_ controller: HistoryWindowController) {
        showPreferences(nil)
    }

    func historyWindowDidRequestManual(_ controller: HistoryWindowController) {
        openManual(nil)
    }

    func historyWindowDidRequestUpdateCheck(_ controller: HistoryWindowController) {
        checkForUpdates(nil)
    }

    func historyWindowDidRequestProjectPage(_ controller: HistoryWindowController) {
        openProjectPage(nil)
    }

    func historyWindowDidRequestContact(_ controller: HistoryWindowController) {
        openContactPage(nil)
    }

    func historyWindowDidRequestDonate(_ controller: HistoryWindowController) {
        openDonatePage(nil)
    }

    func historyWindowDidRequestDiagnostics(_ controller: HistoryWindowController) {
        showDiagnostics(nil)
    }

    func historyWindowDidRequestSettingsFolder(_ controller: HistoryWindowController) {
        openSettingsFolder(nil)
    }

    func historyWindowDidRequestSecrets(_ controller: HistoryWindowController) {
        showSecrets(nil)
    }

    func historyWindowDidHide(_ controller: HistoryWindowController) {
        restorePreviousFrontmostApplication()
    }

    func secretsWindow(_ controller: SecretsWindowController, quickPaste secret: SecretEntry) {
        quickPaste(secret: secret)
    }

    func secretsWindowDidChangeSecrets(_ controller: SecretsWindowController) {
        registerHotkeys()
    }

    func preferencesWindow(_ controller: PreferencesWindowController, didUpdate settings: ClipmanSettings, passwordToSave: String?) {
        let previousSettings = self.settings!
        let previousDatabasePath = previousSettings.databasePath
        self.settings = settings
        saveServerTokenForSettings(settings, previousSettings: previousSettings)
        if let passwordToSave, !passwordToSave.isEmpty {
            applyDatabasePassword(passwordToSave, for: settings.databasePath)
        } else if settings.rememberDatabasePassword,
                  let password = sessionPassword(for: settings.databasePath),
                  !password.isEmpty {
            try? keychain.save(password: password, for: settings.databasePath)
        }
        if !settings.rememberDatabasePassword {
            try? keychain.delete(for: settings.databasePath)
            try? keychain.delete(for: previousDatabasePath)
        }
        if passwordToSave?.isEmpty == false {
            try? secretStore.changeDatabasePassword()
        }
        try? settingsStore.save(settings)
        sounds.useDataFolder(settingsStore.dataFolder(for: settings))
        sounds.isEnabled = settings.soundsEnabled
        monitor.isEnabled = settings.monitoringEnabled
        monitor.ignoredApplications = settings.ignoredApplications
        updateStatusItem()
        applyStartupRegistration(showErrors: true)
        registerHotkeys()
        configureHistoryQuickCopyState()
        resetRemoteClipboardBaseline()
        scheduleUpdateChecks()
        scheduleServerRecoveryChecks()
        seedServerCacheFromConfiguredDatabase()
        let password = currentDatabasePassword(for: settings.databasePath)
        store.setDatabaseURL(textHistoryURL(for: settings), password: password)
        configureTextHistoryServerStorage()
        fileStore = FileHistoryStore(databaseURL: fileHistoryURL(for: settings), machineName: settings.machineName, password: password)
        fileStore.delegate = self
        fileStore.load()
        secretStore.setDatabaseURL(secretsURL(for: settings))
        secretsWindow = nil
        historyWindow.configureSort(
            textSortMode: settings.sortMode,
            textDescending: settings.sortDescending,
            fileSortMode: settings.fileHistorySortMode,
            fileDescending: settings.fileHistorySortDescending,
            selectedTab: settings.lastSelectedTab,
            selectedHistoryTab: settings.lastSelectedHistoryTab,
            linksHistoryEnabled: settings.linksHistoryEnabled,
            groupFilter: settings.groupFilter
        )
        refreshHistoryWindow()
        rebuildMenu()
    }

    private func refreshHistoryWindow() {
        historyWindow.update(entries: sortedTextEntries())
        historyWindow.update(fileEvents: sortedFileEvents())
    }

    private func supportedImportExportTypes() -> [UTType] {
        [
            UTType(filenameExtension: "clipdb"),
            .json,
            .plainText
        ].compactMap { $0 }
    }

    private func transformSelectedEntries(_ entries: [ClipEntry], transform: (String) -> String) {
        let transformed = entries.map { entry in
            (entry.Id, transform(entry.Text))
        }
        guard !transformed.isEmpty else {
            NSSound.beep()
            return
        }
        store.replaceTexts(transformed.map { (id: $0.0, text: $0.1) })
        monitor.writeInternalText(transformed.map { $0.1 }.joined(separator: "\n\n"))
        sounds.play(.copy)
    }

    private func showInformationalAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func configureHistoryQuickCopyState() {
        historyWindow?.configureQuickCopy(
            showHistoryHotkey: settings.showHistoryHotkey,
            toggleMonitoringHotkey: settings.toggleMonitoringHotkey,
            quickCopyHotkeys: settings.quickCopyHotkeys,
            quickPasteModes: settings.quickPasteModes
        )
    }

    private func registerHotkeys() {
        hotkeys.register(
            showHistory: settings.showHistoryHotkey,
            toggleMonitoring: settings.toggleMonitoringHotkey,
            quickCopies: settings.quickCopyHotkeys,
            secrets: secretHotkeys()
        )
    }

    private func secretHotkeys() -> [String: HotkeyDescriptor] {
        Dictionary(uniqueKeysWithValues: secretStore.entries().compactMap { entry in
            guard let descriptor = HotkeyDescriptor.parse(entry.Hotkey), descriptor.isValid else { return nil }
            return (entry.Id, descriptor)
        })
    }

    private func copyLatestRemoteTextIfNeeded() {
        guard settings.autoCopyLatestRemoteText,
              let entry = store.newestRemoteCreatedEntry(excluding: settings.machineName)
        else {
            remoteClipboardBaseline = nil
            return
        }

        let stamp = entry.CreatedUnixMs
        guard let baseline = remoteClipboardBaseline else {
            remoteClipboardBaseline = (entry.Id, stamp)
            return
        }
        guard stamp > baseline.stamp || (stamp == baseline.stamp && entry.Id != baseline.id) else { return }
        remoteClipboardBaseline = (entry.Id, stamp)
        monitor.writeInternalText(TemplateResolver.resolveEntryText(entry))
        sounds.play(.remote)
    }

    private func resetRemoteClipboardBaseline() {
        guard settings.autoCopyLatestRemoteText,
              let entry = store?.newestRemoteCreatedEntry(excluding: settings.machineName)
        else {
            remoteClipboardBaseline = nil
            return
        }
        remoteClipboardBaseline = (entry.Id, entry.CreatedUnixMs)
    }

    private func scheduleUpdateChecks() {
        updateTimer?.invalidate()
        updateTimer = nil
        switch settings.updateCheckFrequency.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "atstartup":
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.runUpdateCheck(manual: false)
            }
        case "hourly":
            updateTimer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.runUpdateCheck(manual: false) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.runUpdateCheckIfDue(intervalSeconds: 60 * 60)
            }
        case "daily":
            updateTimer = Timer.scheduledTimer(withTimeInterval: 60 * 60 * 24, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.runUpdateCheck(manual: false) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.runUpdateCheckIfDue(intervalSeconds: 60 * 60 * 24)
            }
        default:
            break
        }
    }

    private func scheduleServerRecoveryChecks() {
        serverRecoveryTimer?.invalidate()
        serverRecoveryTimer = nil
        guard isServerStorageEnabled(settings) else { return }
        serverRecoveryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recoverServerSyncIfNeeded() }
        }
    }

    private func recoverServerSyncIfNeeded() {
        guard isServerStorageEnabled(settings) else { return }
        let status = store.serverSyncStatus()
        let now = TimeUtil.nowUnixMs()
        let stalePoll = status.configured
            && status.lastPollUnixMs > 0
            && now - status.lastPollUnixMs > 120_000
        guard !serverSyncWarning.isEmpty || stalePoll else { return }

        clearServerSyncWarningIfNeeded()
        seedServerCacheFromConfiguredDatabase()
        let password = currentDatabasePassword(for: settings.databasePath)
        store.setDatabaseURL(textHistoryURL(for: settings), password: password)
        configureTextHistoryServerStorage()
    }

    private func runUpdateCheckIfDue(intervalSeconds: Int64) {
        let now = TimeUtil.nowUnixMs()
        guard settings.lastUpdateCheckUnixMs == 0 || now - settings.lastUpdateCheckUnixMs >= intervalSeconds * 1000 else { return }
        runUpdateCheck(manual: false)
    }

    private func runUpdateCheck(manual: Bool) {
        settings.lastUpdateCheckUnixMs = TimeUtil.nowUnixMs()
        try? settingsStore.save(settings)
        updates.check(
            currentVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0",
            manual: manual,
            installSilently: !manual && settings.installUpdatesSilently
        )
    }

    private func sortedTextEntries() -> [ClipEntry] {
        store.entries(sortMode: settings.sortMode, descending: settings.sortDescending)
    }

    private func sortedFileEvents() -> [FileClipboardEvent] {
        fileStore.events(sortMode: settings.fileHistorySortMode, descending: settings.fileHistorySortDescending)
    }

    private func defaultTextSortDescending(_ sortMode: String) -> Bool {
        switch sortMode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "TEXT", "GROUP", "MACHINE", "MANUAL": return false
        default: return true
        }
    }

    private func defaultFileSortDescending(_ sortMode: String) -> Bool {
        sortMode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "TIME"
    }

    private func fileHistoryURL(for settings: ClipmanSettings) -> URL {
        let safeMachine = settings.machineName
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let fileName = "\(safeMachine.isEmpty ? "Mac" : safeMachine)-file-history.clipdb"
        return URL(fileURLWithPath: settings.databasePath).deletingLastPathComponent().appendingPathComponent(fileName)
    }

    private func secretsURL(for settings: ClipmanSettings) -> URL {
        let safeMachine = settings.machineName
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let fileName = "\(safeMachine.isEmpty ? "Mac" : safeMachine)-secrets.clipdb"
        return URL(fileURLWithPath: settings.databasePath)
            .deletingLastPathComponent()
            .appendingPathComponent(fileName)
    }

    private func textHistoryURL(for settings: ClipmanSettings) -> URL {
        guard isServerStorageEnabled(settings) else {
            return URL(fileURLWithPath: settings.databasePath)
        }
        let safeMachine = settings.machineName
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return settingsStore.applicationSupportURL
            .appendingPathComponent("ServerCache", isDirectory: true)
            .appendingPathComponent(safeMachine.isEmpty ? "Mac" : safeMachine, isDirectory: true)
            .appendingPathComponent("clipman-history.clipdb")
    }

    private func seedServerCacheFromConfiguredDatabase() {
        guard isServerStorageEnabled(settings) else { return }
        let cacheURL = textHistoryURL(for: settings)
        guard !FileManager.default.fileExists(atPath: cacheURL.path) else { return }
        let configuredURL = URL(fileURLWithPath: settings.databasePath)
        guard FileManager.default.fileExists(atPath: configuredURL.path) else { return }
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: configuredURL, to: cacheURL)
        } catch {
            storageUnavailableReasons["text"] = error.localizedDescription
            rebuildMenu()
        }
    }

    private func isServerStorageEnabled(_ settings: ClipmanSettings) -> Bool {
        settings.storageMode.caseInsensitiveCompare("Server") == .orderedSame
    }

    private func configureTextHistoryServerStorage() {
        store.configureServerStorage(
            enabled: isServerStorageEnabled(settings),
            serverURL: settings.serverUrl,
            serverToken: settings.serverToken
        )
    }

    private func serverTokenAccount(for settings: ClipmanSettings) -> String {
        "server-token:" + settings.databasePath
    }

    private func currentServerToken(for settings: ClipmanSettings) -> String {
        let plain = ServerSettingsSanitizer.cleanToken(settings.serverToken)
        if !plain.isEmpty {
            return plain
        }
        return ServerSettingsSanitizer.cleanToken(serverTokenKeychain.password(for: serverTokenAccount(for: settings)))
    }

    private func saveServerTokenForSettings(_ settings: ClipmanSettings, previousSettings: ClipmanSettings? = nil) {
        let account = serverTokenAccount(for: settings)
        let token = ServerSettingsSanitizer.cleanToken(settings.serverToken)
        if token.isEmpty {
            try? serverTokenKeychain.delete(for: account)
        } else {
            try? serverTokenKeychain.save(password: token, for: account)
        }
        if let previousSettings {
            let previousAccount = serverTokenAccount(for: previousSettings)
            if previousAccount != account {
                try? serverTokenKeychain.delete(for: previousAccount)
            }
        }
    }

    private func migrateServerTokenToKeychainIfNeeded() {
        let token = ServerSettingsSanitizer.cleanToken(settings.serverToken)
        if token.isEmpty {
            settings.serverToken = currentServerToken(for: settings)
            return
        }
        saveServerTokenForSettings(settings)
        try? settingsStore.save(settings)
    }

    private func databasePasswordIdentityPath(for path: String) -> String {
        if isServerStorageEnabled(settings) {
            return settings.databasePath
        }
        return path
    }

    private func migrateLegacyKeychainPasswordIfNeeded() {
        guard !settingsStore.loadedSettingsHadRememberDatabasePassword,
              keychain.hasPassword(for: settings.databasePath) else {
            if !settings.rememberDatabasePassword {
                try? keychain.delete(for: settings.databasePath)
            }
            return
        }
        settings.rememberDatabasePassword = true
        try? settingsStore.save(settings)
    }

    private func initialDatabasePassword() -> String {
        let password = currentDatabasePassword(for: settings.databasePath)
        if !password.isEmpty {
            return password
        }
        guard encryptedHistoryExists(for: settings),
              !cancelledPasswordPaths.contains(settings.databasePath)
        else { return "" }
        guard let entered = promptForDatabasePassword(path: settings.databasePath) else {
            cancelledPasswordPaths.insert(settings.databasePath)
            return ""
        }
        applyDatabasePassword(entered, for: settings.databasePath)
        return entered
    }

    private func currentDatabasePassword(for path: String) -> String {
        if settings.rememberDatabasePassword {
            let remembered = keychain.password(for: path)
            if !remembered.isEmpty {
                sessionDatabasePassword = remembered
                sessionPasswordDatabasePath = path
            }
            return remembered
        }
        return sessionPassword(for: path) ?? ""
    }

    private func sessionPassword(for path: String) -> String? {
        guard sessionPasswordDatabasePath == path else { return nil }
        return sessionDatabasePassword
    }

    private func applyDatabasePassword(_ password: String, for path: String) {
        sessionDatabasePassword = password
        sessionPasswordDatabasePath = path
        cancelledPasswordPaths.remove(path)
        if settings.rememberDatabasePassword {
            try? keychain.save(password: password, for: path)
        } else {
            try? keychain.delete(for: path)
        }
        if fileStore != nil {
            fileStore.setPassword(password)
        }
    }

    private func encryptedHistoryExists(for settings: ClipmanSettings) -> Bool {
        ClipDatabaseFile.isEncryptedFile(textHistoryURL(for: settings))
            || ClipDatabaseFile.isEncryptedFile(URL(fileURLWithPath: settings.databasePath))
            || ClipDatabaseFile.isEncryptedFile(fileHistoryURL(for: settings))
            || ClipDatabaseFile.isEncryptedFile(secretsURL(for: settings))
    }

    private func rememberPreviousFrontmostApplication() {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != NSRunningApplication.current.processIdentifier
        else { return }
        previousFrontmostApplication = application
    }

    private func restorePreviousFrontmostApplication() {
        guard let application = previousFrontmostApplication,
              !application.isTerminated
        else { return }
        previousFrontmostApplication = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            application.activate(options: [.activateAllWindows])
        }
    }

    private func applyStartupRegistration(showErrors: Bool) {
        do {
            try startup.setEnabled(settings.runAtStartup, appBundleURL: Bundle.main.bundleURL)
        } catch {
            guard showErrors else { return }
            let alert = NSAlert(error: error)
            alert.messageText = "Could Not Update Login Setting"
            alert.informativeText = "Clipman could not update its LaunchAgent. Try moving Clipman to Applications and saving Preferences again."
            alert.runModal()
        }
    }
}
