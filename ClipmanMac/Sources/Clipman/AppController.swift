import AppKit
import ClipmanCore

@MainActor
final class AppController: NSObject, NSApplicationDelegate, ClipStoreDelegate, FileHistoryStoreDelegate, ClipboardMonitorDelegate, HistoryWindowControllerDelegate, PreferencesWindowControllerDelegate {
    private let settingsStore = SettingsStore()
    private let keychain = KeychainPasswordStore()
    private let monitor = ClipboardMonitor()
    private let hotkeys = HotkeyManager()
    private let startup = StartupService()
    private lazy var sounds = SoundService(applicationSupportURL: settingsStore.applicationSupportURL)
    private var settings: ClipmanSettings!
    private var store: ClipStore!
    private var fileStore: FileHistoryStore!
    private var statusItem: NSStatusItem!
    private var historyWindow: HistoryWindowController!
    private var preferencesWindow: PreferencesWindowController?
    private weak var previousFrontmostApplication: NSRunningApplication?
    private var sessionDatabasePassword = ""
    private var sessionPasswordDatabasePath = ""
    private var cancelledPasswordPaths = Set<String>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings = settingsStore.load()
        migrateLegacyKeychainPasswordIfNeeded()
        let initialPassword = initialDatabasePassword()
        store = ClipStore(databaseURL: URL(fileURLWithPath: settings.databasePath), machineName: settings.machineName)
        store.delegate = self
        store.setDatabaseURL(URL(fileURLWithPath: settings.databasePath), password: initialPassword)
        fileStore = FileHistoryStore(databaseURL: fileHistoryURL(for: settings), machineName: settings.machineName, password: initialPassword)
        fileStore.delegate = self
        fileStore.load()

        historyWindow = HistoryWindowController()
        historyWindow.historyDelegate = self
        historyWindow.configureSort(
            textSortMode: settings.sortMode,
            textDescending: settings.sortDescending,
            fileSortMode: settings.fileHistorySortMode,
            fileDescending: settings.fileHistorySortDescending,
            selectedTab: settings.lastSelectedTab,
            groupFilter: settings.groupFilter
        )
        monitor.delegate = self
        monitor.isEnabled = settings.monitoringEnabled
        monitor.start()
        monitor.captureCurrentContents()
        sounds.play(settings.monitoringEnabled ? .on : .off)
        applyStartupRegistration(showErrors: false)

        buildStatusItem()
        hotkeys.handler = { [weak self] action in
            switch action {
            case .showHistory: self?.showHistory(nil)
            case .toggleMonitoring: self?.toggleMonitoring(nil)
            }
        }
        hotkeys.register(showHistory: settings.showHistoryHotkey, toggleMonitoring: settings.toggleMonitoringHotkey)
        NSApp.setActivationPolicy(.accessory)
        buildMainMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
        hotkeys.unregisterAll()
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Clipman"
        statusItem.button?.toolTip = "Clipman"
        statusItem.button?.setAccessibilityLabel("Clipman")
        rebuildMenu()
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu(title: "Clipman")
        let appMenuItem = NSMenuItem(title: "Clipman", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "Clipman")
        appMenu.addItem(NSMenuItem(title: "Show History", action: #selector(showHistory(_:)), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem(title: "Show File History", action: #selector(showFileHistory(_:)), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem(title: "Toggle Monitoring", action: #selector(toggleMonitoring(_:)), keyEquivalent: ""))
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
        let menu = NSMenu(title: "Clipman")
        menu.addItem(NSMenuItem(title: "Show History", action: #selector(showHistory(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Show File History", action: #selector(showFileHistory(_:)), keyEquivalent: ""))
        let monitorTitle = settings.monitoringEnabled ? "Turn Monitoring Off" : "Turn Monitoring On"
        menu.addItem(NSMenuItem(title: monitorTitle, action: #selector(toggleMonitoring(_:)), keyEquivalent: ""))
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
    }

    @objc private func showFileHistory(_ sender: Any?) {
        showHistory(sender)
        historyWindow.showFileHistory()
    }

    @objc private func toggleMonitoring(_ sender: Any?) {
        settings.monitoringEnabled.toggle()
        monitor.isEnabled = settings.monitoringEnabled
        try? settingsStore.save(settings)
        sounds.play(settings.monitoringEnabled ? .on : .off)
        rebuildMenu()
    }

    @objc private func showPreferences(_ sender: Any?) {
        if preferencesWindow == nil {
            preferencesWindow = PreferencesWindowController(settings: settings)
            preferencesWindow?.preferencesDelegate = self
        } else {
            preferencesWindow?.update(settings: settings)
        }
        preferencesWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
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

    func clipboardMonitor(_ monitor: ClipboardMonitor, didCapture text: String) {
        store.addText(text)
        sounds.play(.copy)
    }

    func clipboardMonitor(_ monitor: ClipboardMonitor, didCaptureFiles files: [String], formats: [String], containsText: Bool) {
        fileStore.add(files: files, formats: formats, containsText: containsText)
        sounds.play(.copy)
    }

    func clipStoreDidChange() {
        historyWindow.update(entries: sortedTextEntries())
    }

    func fileHistoryStoreDidChange() {
        historyWindow.update(fileEvents: sortedFileEvents())
    }

    func fileHistoryStoreDidFail(error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = "Clipman File History Error"
        alert.runModal()
    }

    func clipStoreNeedsPassword(for path: String) -> String? {
        if let password = sessionPassword(for: path), !password.isEmpty {
            return password
        }
        guard !cancelledPasswordPaths.contains(path) else { return nil }
        guard let password = promptForDatabasePassword(path: path) else {
            cancelledPasswordPaths.insert(path)
            return nil
        }
        applyDatabasePassword(password, for: path)
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
        let alert = NSAlert(error: error)
        alert.messageText = "Clipman Database Error"
        alert.runModal()
    }

    func historyWindow(_ controller: HistoryWindowController, didChoose entry: ClipEntry) {
        monitor.writeInternalText(entry.Text)
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

    func historyWindow(_ controller: HistoryWindowController, didCopy entries: [ClipEntry]) {
        let text = entries.map(\.Text).joined(separator: "\n---\n")
        monitor.writeInternalText(text)
        sounds.play(.copy)
    }

    func historyWindow(_ controller: HistoryWindowController, didCut entries: [ClipEntry]) {
        historyWindow(controller, didCopy: entries)
        for entry in entries where !entry.Pinned {
            store.delete(entry.Id)
        }
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

    func historyWindowDidRequestClearNormalFileHistory(_ controller: HistoryWindowController) {
        fileStore.clearNormal()
    }

    func historyWindowDidRequestRemoveUnavailableFileHistory(_ controller: HistoryWindowController) {
        fileStore.removeUnavailable()
    }

    func historyWindow(_ controller: HistoryWindowController, didChangeModeToFileHistory isFileHistory: Bool) {
        settings.lastSelectedTab = isFileHistory ? 1 : 0
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

    func historyWindowDidHide(_ controller: HistoryWindowController) {
        restorePreviousFrontmostApplication()
    }

    func preferencesWindow(_ controller: PreferencesWindowController, didUpdate settings: ClipmanSettings, passwordToSave: String?) {
        let previousDatabasePath = self.settings.databasePath
        self.settings = settings
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
        try? settingsStore.save(settings)
        monitor.isEnabled = settings.monitoringEnabled
        applyStartupRegistration(showErrors: true)
        hotkeys.register(showHistory: settings.showHistoryHotkey, toggleMonitoring: settings.toggleMonitoringHotkey)
        let password = currentDatabasePassword(for: settings.databasePath)
        store.setDatabaseURL(URL(fileURLWithPath: settings.databasePath), password: password)
        fileStore = FileHistoryStore(databaseURL: fileHistoryURL(for: settings), machineName: settings.machineName, password: password)
        fileStore.delegate = self
        fileStore.load()
        rebuildMenu()
    }

    private func refreshHistoryWindow() {
        historyWindow.update(entries: sortedTextEntries())
        historyWindow.update(fileEvents: sortedFileEvents())
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
        ClipDatabaseFile.isEncryptedFile(URL(fileURLWithPath: settings.databasePath))
            || ClipDatabaseFile.isEncryptedFile(fileHistoryURL(for: settings))
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
