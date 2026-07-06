import AppKit
import UniformTypeIdentifiers
import Carbon

@MainActor
protocol PreferencesWindowControllerDelegate: AnyObject {
    func preferencesWindow(_ controller: PreferencesWindowController, didUpdate settings: ClipmanSettings, passwordToSave: String?)
}

final class PreferencesWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        close()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            close()
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "w" {
            close()
            return true
        }
        if modifiers.contains(.command),
           !modifiers.contains(.option),
           !modifiers.contains(.control),
           let command = event.charactersIgnoringModifiers?.lowercased() {
            switch command {
            case "x":
                return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self)
            case "c":
                return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self)
            case "v":
                return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self)
            case "a":
                return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self)
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class PreferencesWindowController: NSWindowController, HotkeyCaptureFieldDelegate {
    weak var preferencesDelegate: PreferencesWindowControllerDelegate?
    private var settings: ClipmanSettings
    private var historyIsEncrypted: Bool
    private var rememberedPasswordExists: Bool
    private let databasePathField = NSTextField()
    private let monitoringCheckbox = NSButton(checkboxWithTitle: "Monitoring enabled", target: nil, action: nil)
    private let soundsCheckbox = NSButton(checkboxWithTitle: "Play sounds", target: nil, action: nil)
    private let runAtStartupCheckbox = NSButton(checkboxWithTitle: "Run Clipman at login", target: nil, action: nil)
    private let rememberPasswordCheckbox = NSButton(checkboxWithTitle: "Remember history password in Keychain", target: nil, action: nil)
    private let autoCopyRemoteCheckbox = NSButton(checkboxWithTitle: "Copy latest remote text to this Mac clipboard", target: nil, action: nil)
    private let installUpdatesSilentlyCheckbox = NSButton(checkboxWithTitle: "Install updates silently", target: nil, action: nil)
    private let updateFrequencyPopup = NSPopUpButton()
    private let showHotkeyField = HotkeyCaptureField()
    private let toggleHotkeyField = HotkeyCaptureField()
    private let passwordField = NSSecureTextField()
    private let ignoredApplicationsView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "")

    init(settings: ClipmanSettings, historyIsEncrypted: Bool, rememberedPasswordExists: Bool) {
        self.settings = settings
        self.historyIsEncrypted = historyIsEncrypted
        self.rememberedPasswordExists = rememberedPasswordExists
        let window = PreferencesWindow(
            contentRect: NSRect(x: 140, y: 140, width: 760, height: 660),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Clipman Preferences"
        super.init(window: window)
        buildUI()
        loadFields()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(settings: ClipmanSettings, historyIsEncrypted: Bool, rememberedPasswordExists: Bool) {
        self.settings = settings
        self.historyIsEncrypted = historyIsEncrypted
        self.rememberedPasswordExists = rememberedPasswordExists
        loadFields()
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let grid = NSGridView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 10
        grid.columnSpacing = 8
        content.addSubview(grid)

        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 16)
        ])

        addRow("Settings folder", databasePathField, button(title: "Choose...", action: #selector(chooseSettingsFolder)))
        databasePathField.setAccessibilityHelp("Choose the Clipman data/settings folder. Clipman will use clipman-history.clipdb inside that folder.")
        addRow("Show history hotkey", showHotkeyField)
        addRow("Toggle monitoring hotkey", toggleHotkeyField)
        addRow("History password", passwordField)
        rememberPasswordCheckbox.setAccessibilityLabel("Remember history password in Keychain")
        rememberPasswordCheckbox.setAccessibilityHelp("When checked, Clipman stores the history password in this Mac user's Keychain. When unchecked, Clipman asks for the password each app session and keeps it only in memory.")
        grid.addRow(with: [NSGridCell.emptyContentView, rememberPasswordCheckbox])
        addIgnoredApplicationsRow(to: grid)
        showHotkeyField.hotkeyDelegate = self
        toggleHotkeyField.hotkeyDelegate = self

        monitoringCheckbox.target = nil
        monitoringCheckbox.action = nil
        monitoringCheckbox.setAccessibilityLabel("Monitoring enabled")
        grid.addRow(with: [NSGridCell.emptyContentView, monitoringCheckbox])

        soundsCheckbox.target = nil
        soundsCheckbox.action = nil
        soundsCheckbox.setAccessibilityLabel("Play sounds")
        soundsCheckbox.setAccessibilityHelp("When checked, Clipman plays sounds for copy, remote sync, monitoring on, monitoring off, and skipped clipboard events.")
        grid.addRow(with: [NSGridCell.emptyContentView, soundsCheckbox])

        runAtStartupCheckbox.target = nil
        runAtStartupCheckbox.action = nil
        runAtStartupCheckbox.setAccessibilityLabel("Run Clipman at login")
        grid.addRow(with: [NSGridCell.emptyContentView, runAtStartupCheckbox])

        autoCopyRemoteCheckbox.target = nil
        autoCopyRemoteCheckbox.action = nil
        autoCopyRemoteCheckbox.setAccessibilityLabel("Copy latest remote text to this Mac clipboard")
        autoCopyRemoteCheckbox.setAccessibilityHelp("When enabled, new text copied on another machine sharing this database is placed on this Mac clipboard. This is off by default.")
        grid.addRow(with: [NSGridCell.emptyContentView, autoCopyRemoteCheckbox])

        updateFrequencyPopup.addItems(withTitles: ["Never", "At startup", "Hourly", "Daily"])
        updateFrequencyPopup.setAccessibilityLabel("Check for updates")
        addRow("Check for updates", updateFrequencyPopup)

        installUpdatesSilentlyCheckbox.target = nil
        installUpdatesSilentlyCheckbox.action = nil
        installUpdatesSilentlyCheckbox.setAccessibilityLabel("Install updates silently")
        installUpdatesSilentlyCheckbox.setAccessibilityHelp("When checked, Clipman installs available Mac updates in the background and relaunches itself.")
        grid.addRow(with: [NSGridCell.emptyContentView, installUpdatesSilentlyCheckbox])

        let saveButton = button(title: "Save and Close", action: #selector(saveClicked))
        let buttonStack = NSStackView(views: [saveButton])
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .trailing
        grid.addRow(with: [NSGridCell.emptyContentView, buttonStack])

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 3
        grid.addRow(with: [NSGridCell.emptyContentView, statusLabel])
    }

    private func addRow(_ label: String, _ field: NSControl, _ trailing: NSView? = nil) {
        guard let grid = window?.contentView?.subviews.first(where: { $0 is NSGridView }) as? NSGridView else { return }
        let labelView = NSTextField(labelWithString: label)
        labelView.alignment = .right
        field.setAccessibilityLabel(label)
        if let trailing {
            let stack = NSStackView(views: [field, trailing])
            stack.orientation = .horizontal
            stack.spacing = 8
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 340).isActive = true
            grid.addRow(with: [labelView, stack])
        } else {
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 430).isActive = true
            grid.addRow(with: [labelView, field])
        }
    }

    private func button(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func loadFields() {
        databasePathField.stringValue = settingsFolderPath(fromDatabasePath: settings.databasePath)
        monitoringCheckbox.state = settings.monitoringEnabled ? .on : .off
        soundsCheckbox.state = settings.soundsEnabled ? .on : .off
        runAtStartupCheckbox.state = settings.runAtStartup ? .on : .off
        rememberPasswordCheckbox.state = settings.rememberDatabasePassword ? .on : .off
        autoCopyRemoteCheckbox.state = settings.autoCopyLatestRemoteText ? .on : .off
        installUpdatesSilentlyCheckbox.state = settings.installUpdatesSilently ? .on : .off
        updateFrequencyPopup.selectItem(withTitle: displayUpdateFrequency(settings.updateCheckFrequency))
        showHotkeyField.descriptor = settings.showHistoryHotkey
        toggleHotkeyField.descriptor = settings.toggleMonitoringHotkey
        passwordField.stringValue = ""
        ignoredApplicationsView.string = settings.ignoredApplications.joined(separator: "\n")
        statusLabel.stringValue = passwordStatusText()
    }

    @objc private func chooseSettingsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            databasePathField.stringValue = url.path
        }
    }

    @objc private func saveClicked() {
        guard let show = showHotkeyField.descriptor ?? HotkeyDescriptor.parse(showHotkeyField.stringValue), show.isValid else {
            statusLabel.stringValue = "Show history hotkey must use two modifiers, or one modifier with F1-F12, Grave, Backslash, or ISO section. Escape, Tab, Backspace, Return, Space, and Command+Grave are not available."
            return
        }
        guard let toggle = toggleHotkeyField.descriptor ?? HotkeyDescriptor.parse(toggleHotkeyField.stringValue), toggle.isValid else {
            statusLabel.stringValue = "Toggle monitoring hotkey must use two modifiers, or one modifier with F1-F12, Grave, Backslash, or ISO section. Escape, Tab, Backspace, Return, Space, and Command+Grave are not available."
            return
        }
        guard show != toggle else {
            statusLabel.stringValue = "Show history and toggle monitoring cannot use the same hotkey."
            return
        }
        guard confirmSingleModifierHotkeys(show: show, toggle: toggle) else {
            return
        }
        settings.databasePath = normalizedDatabasePath(databasePathField.stringValue)
        settings.monitoringEnabled = monitoringCheckbox.state == .on
        settings.soundsEnabled = soundsCheckbox.state == .on
        settings.runAtStartup = runAtStartupCheckbox.state == .on
        settings.rememberDatabasePassword = rememberPasswordCheckbox.state == .on
        settings.autoCopyLatestRemoteText = autoCopyRemoteCheckbox.state == .on
        settings.installUpdatesSilently = installUpdatesSilentlyCheckbox.state == .on
        settings.updateCheckFrequency = storedUpdateFrequency(updateFrequencyPopup.titleOfSelectedItem ?? "Never")
        settings.showHistoryHotkey = show
        settings.toggleMonitoringHotkey = toggle
        settings.ignoredApplications = normalizedIgnoredApplications(ignoredApplicationsView.string)
        let password = passwordField.stringValue.isEmpty ? nil : passwordField.stringValue
        preferencesDelegate?.preferencesWindow(self, didUpdate: settings, passwordToSave: password)
        statusLabel.stringValue = "Preferences saved."
        window?.close()
    }

    private func confirmSingleModifierHotkeys(show: HotkeyDescriptor, toggle: HotkeyDescriptor) -> Bool {
        guard show.usesSingleModifier || toggle.usesSingleModifier else {
            return true
        }

        let alert = NSAlert()
        alert.messageText = "Keep single-modifier hotkey?"
        alert.informativeText = "One of your global hotkeys uses only one modifier. Clipman allows this for compatibility, but it is more likely to conflict with other apps or keyboard layouts."
        alert.addButton(withTitle: "Keep")
        alert.addButton(withTitle: "Go Back")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            return true
        }
        statusLabel.stringValue = "Single-modifier hotkey not saved."
        return false
    }

    func hotkeyCaptureFieldDidChange(_ field: HotkeyCaptureField) {
        statusLabel.stringValue = "Captured \(field.stringValue)."
    }

    private func passwordStatusText() -> String {
        if historyIsEncrypted {
            if settings.rememberDatabasePassword && rememberedPasswordExists {
                return "Database encryption is on. The password is saved in Keychain, so the password field is blank for security. Leave it blank to keep the saved password."
            }
            if settings.rememberDatabasePassword {
                return "Database encryption is on. Remember in Keychain is enabled, but no saved password was found yet. Enter the password to save it."
            }
            return "Database encryption is on. The password is not saved; Clipman will ask for it each app session. Leave the field blank to keep the current session password."
        }
        if settings.rememberDatabasePassword && rememberedPasswordExists {
            return "Database encryption will be used when Clipman next writes history. The password is saved in Keychain and the field is blank for security."
        }
        return "Database encryption is off. Type and save a history password to encrypt future history writes, or leave it blank for no password."
    }

    private func normalizedDatabasePath(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = URL(fileURLWithPath: trimmed)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return url.appendingPathComponent("clipman-history.clipdb").path
        }
        if url.lastPathComponent.lowercased() == "settings" || url.pathExtension.isEmpty {
            return url.appendingPathComponent("clipman-history.clipdb").path
        }
        return trimmed
    }

    private func settingsFolderPath(fromDatabasePath value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let url = URL(fileURLWithPath: trimmed)
        if url.lastPathComponent.lowercased() == "clipman-history.clipdb" {
            return url.deletingLastPathComponent().path
        }
        if url.pathExtension.lowercased() == "clipdb" {
            return url.deletingLastPathComponent().path
        }
        return trimmed
    }

    private func displayUpdateFrequency(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "startup", "atstartup", "at startup": return "At startup"
        case "hourly": return "Hourly"
        case "daily": return "Daily"
        default: return "Never"
        }
    }

    private func storedUpdateFrequency(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "at startup": return "AtStartup"
        case "hourly": return "Hourly"
        case "daily": return "Daily"
        default: return "Never"
        }
    }

    private func addIgnoredApplicationsRow(to grid: NSGridView) {
        let labelView = NSTextField(labelWithString: "Ignored applications")
        labelView.alignment = .right
        ignoredApplicationsView.isRichText = false
        ignoredApplicationsView.isAutomaticQuoteSubstitutionEnabled = false
        ignoredApplicationsView.isAutomaticDashSubstitutionEnabled = false
        ignoredApplicationsView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        ignoredApplicationsView.setAccessibilityLabel("Ignored applications")
        ignoredApplicationsView.setAccessibilityHelp("One Mac app name, bundle identifier, or executable name per line, such as Safari, com.apple.TextEdit, or KeePassXC.")

        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.documentView = ignoredApplicationsView
        scroll.heightAnchor.constraint(equalToConstant: 96).isActive = true
        scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 430).isActive = true
        grid.addRow(with: [labelView, scroll])

        let note = NSTextField(labelWithString: "One Mac app name, bundle identifier, or executable name per line. Examples: Safari, com.apple.TextEdit, KeePassXC.")
        note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byWordWrapping
        note.maximumNumberOfLines = 2
        grid.addRow(with: [NSGridCell.emptyContentView, note])
    }

    private func normalizedIgnoredApplications(_ value: String) -> [String] {
        var seen = Set<String>()
        return value
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { item in
                let key = item.lowercased()
                guard !seen.contains(key) else { return false }
                seen.insert(key)
                return true
            }
    }
}
