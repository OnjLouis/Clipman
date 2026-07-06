import AppKit
import Carbon
import ClipmanCore
import UniformTypeIdentifiers

@MainActor
final class AppController: NSObject, NSApplicationDelegate, ClipStoreDelegate, FileHistoryStoreDelegate, ClipboardMonitorDelegate, HistoryWindowControllerDelegate, PreferencesWindowControllerDelegate {
    private let settingsStore = SettingsStore()
    private let keychain = KeychainPasswordStore()
    private let monitor = ClipboardMonitor()
    private let hotkeys = HotkeyManager()
    private let startup = StartupService()
    private let updates = UpdateService()
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
    private var remoteClipboardBaseline: (id: String, stamp: Int64)?
    private var updateTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings = settingsStore.load()
        sounds.useDataFolder(settingsStore.dataFolder(for: settings))
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
        configureHistoryQuickCopyState()
        sounds.isEnabled = settings.soundsEnabled
        monitor.delegate = self
        monitor.isEnabled = settings.monitoringEnabled
        monitor.ignoredApplications = settings.ignoredApplications
        monitor.start()
        monitor.captureCurrentContents()
        sounds.play(settings.monitoringEnabled ? .on : .off)
        applyStartupRegistration(showErrors: false)

        buildStatusItem()
        hotkeys.handler = { [weak self] action in
            switch action {
            case .showHistory: self?.toggleHistoryFromHotkey()
            case .toggleMonitoring: self?.toggleMonitoring(nil)
            case .quickCopy(let entryID): self?.quickPasteEntry(id: entryID)
            }
        }
        registerHotkeys()
        NSApp.setActivationPolicy(.accessory)
        buildMainMenu()
        scheduleUpdateChecks()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
        hotkeys.unregisterAll()
        updateTimer?.invalidate()
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
        appMenu.addItem(NSMenuItem(title: "Open Manual", action: #selector(openManual(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates(_:)), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem(title: "Version History...", action: #selector(openVersionHistory(_:)), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem(title: "Project Page", action: #selector(openProjectPage(_:)), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem(title: "Contact", action: #selector(openContactPage(_:)), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem(title: "Donate", action: #selector(openDonatePage(_:)), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem(title: "Diagnostics...", action: #selector(showDiagnostics(_:)), keyEquivalent: ""))
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
        menu.addItem(NSMenuItem(title: "Open Manual", action: #selector(openManual(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Version History...", action: #selector(openVersionHistory(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Project Page", action: #selector(openProjectPage(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Contact", action: #selector(openContactPage(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Donate", action: #selector(openDonatePage(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Diagnostics...", action: #selector(showDiagnostics(_:)), keyEquivalent: ""))
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

    @objc private func toggleMonitoring(_ sender: Any?) {
        settings.monitoringEnabled.toggle()
        monitor.isEnabled = settings.monitoringEnabled
        try? settingsStore.save(settings)
        sounds.play(settings.monitoringEnabled ? .on : .off)
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
        let dataFolder = URL(fileURLWithPath: settings.databasePath).deletingLastPathComponent().path
        let report = [
            "Clipman diagnostics",
            "",
            "Version: \(version)",
            "Build: \(build)",
            "Machine: \(settings.machineName)",
            "Monitoring: \(settings.monitoringEnabled ? "On" : "Off")",
            "Data folder: \(dataFolder)",
            "Text history: \(settings.databasePath)",
            "Text entries: \(store.entryCount())",
            "File history: \(fileHistoryURL(for: settings).path)",
            "File events: \(fileStore.eventCount())",
            "Runtime crash log: \(RuntimeLogger.logURL.path)",
            "Text sort: \(settings.sortMode), \(settings.sortDescending ? "descending" : "ascending")",
            "File sort: \(settings.fileHistorySortMode), \(settings.fileHistorySortDescending ? "descending" : "ascending")",
            "Group filter: \(settings.groupFilter)",
            "Remember password: \(settings.rememberDatabasePassword ? "On" : "Off")",
            "Run at login: \(settings.runAtStartup ? "On" : "Off")",
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
        store.addText(text, group: sourceApplication)
        sounds.play(.copy)
    }

    func clipboardMonitor(_ monitor: ClipboardMonitor, didCaptureFiles files: [String], formats: [String], containsText: Bool) {
        fileStore.add(files: files, formats: formats, containsText: containsText)
        sounds.play(.copy)
    }

    func clipboardMonitorDidSkipIgnoredApplication(_ monitor: ClipboardMonitor) {
        sounds.play(.skip)
    }

    func clipStoreDidChange() {
        historyWindow.update(entries: sortedTextEntries())
        copyLatestRemoteTextIfNeeded()
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
        store.importEntries(from: url) { [weak self] result in
            Task { @MainActor in
                switch result {
                case .success(let count):
                    self?.showInformationalAlert(
                        title: "Import Complete",
                        message: count == 1 ? "Imported one clipboard entry." : "Imported \(count) clipboard entries."
                    )
                case .failure:
                    break
                }
            }
        }
    }

    func historyWindowDidRequestExport(_ controller: HistoryWindowController) {
        let panel = NSSavePanel()
        panel.title = "Export Clipboard Entries"
        panel.prompt = "Export"
        panel.nameFieldStringValue = "clipman-export.clipdb"
        panel.allowedContentTypes = supportedImportExportTypes()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.exportDatabase(to: url) { [weak self] result in
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

    func historyWindow(_ controller: HistoryWindowController, didCleanURLTracking entries: [ClipEntry]) {
        transformSelectedEntries(entries, transform: URLTrackingCleaner.cleanText(_:))
    }

    func historyWindow(_ controller: HistoryWindowController, didCleanLinksForSharing entries: [ClipEntry]) {
        transformSelectedEntries(entries, transform: URLTrackingCleaner.cleanForSharing(_:))
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
        sounds.useDataFolder(settingsStore.dataFolder(for: settings))
        sounds.isEnabled = settings.soundsEnabled
        monitor.isEnabled = settings.monitoringEnabled
        monitor.ignoredApplications = settings.ignoredApplications
        applyStartupRegistration(showErrors: true)
        registerHotkeys()
        configureHistoryQuickCopyState()
        resetRemoteClipboardBaseline()
        scheduleUpdateChecks()
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
            quickCopies: settings.quickCopyHotkeys
        )
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
