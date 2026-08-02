import AppKit
import UniformTypeIdentifiers
import Carbon
import ClipmanCore

@MainActor
protocol PreferencesWindowControllerDelegate: AnyObject {
    func preferencesWindow(_ controller: PreferencesWindowController, didUpdate settings: ClipmanSettings, passwordToSave: String?) -> Bool
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

private final class PreferencesTabTextView: NSTextView {
    override func insertTab(_ sender: Any?) {
        window?.selectNextKeyView(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        window?.selectPreviousKeyView(sender)
    }
}

private let imageMetadataPrivacyText = "Retained image metadata may contain camera or location information and follows your history encryption and sync choices."
private let includeImagesEnabledAccessibilityHelp = "When checked, standalone PNG and JPEG clipboard images can be optimized and stored in Rich Text history. \(imageMetadataPrivacyText) Each image is limited to 512 KiB and all embedded images together are limited to 8 MiB. This is off by default."

final class PreferencesWindowController: NSWindowController, HotkeyCaptureFieldDelegate {
    weak var preferencesDelegate: PreferencesWindowControllerDelegate?
    private var settings: ClipmanSettings
    private var historyIsEncrypted: Bool
    private var rememberedPasswordExists: Bool
    private var databasePasswordAvailable: Bool
    private let databasePathField = NSTextField()
    private let machineNameField = NSTextField()
    private let storageModePopup = NSPopUpButton()
    private let serverUrlField = NSTextField()
    private let serverTokenField = NSSecureTextField()
    private let serverAuthorityStatus = NSTextField(wrappingLabelWithString: "")
    private let serverAuthorityFingerprint = NSTextField()
    private let monitoringCheckbox = NSButton(checkboxWithTitle: "Monitoring enabled", target: nil, action: nil)
    private let soundsCheckbox = NSButton(checkboxWithTitle: "Play sounds", target: nil, action: nil)
    private let runAtStartupCheckbox = NSButton(checkboxWithTitle: "Run Clipman at login", target: nil, action: nil)
    private let captureClipboardOnStartupCheckbox = NSButton(checkboxWithTitle: "Add current clipboard item to Clipman on start", target: nil, action: nil)
    private let rememberPasswordCheckbox = NSButton(checkboxWithTitle: "Remember history password in Keychain", target: nil, action: nil)
    private let autoCopyRemoteCheckbox = NSButton(checkboxWithTitle: "Copy latest remote text to this Mac clipboard", target: nil, action: nil)
    private let pasteAfterEnterCheckbox = NSButton(checkboxWithTitle: "After Enter, paste into the previous application", target: nil, action: nil)
    private let dynamicHistoryModeCheckbox = NSButton(checkboxWithTitle: "Open history to the most recent clipboard type", target: nil, action: nil)
    private let linksHistoryCheckbox = NSButton(checkboxWithTitle: "Show Links history tab", target: nil, action: nil)
    private let richTextHistoryCheckbox = NSButton(checkboxWithTitle: "Preserve copied formatting and show Rich Text history", target: nil, action: nil)
    private let includeImagesCheckbox = NSButton(checkboxWithTitle: "Include images in Rich Text history", target: nil, action: nil)
    private let alsoAddCopiedImageFilesCheckbox = NSButton(checkboxWithTitle: "Also add copied PNG and JPEG files to Rich Text history", target: nil, action: nil)
    private let includeImagesPrivacyLabel = NSTextField(wrappingLabelWithString: imageMetadataPrivacyText)
    private let confirmDeletionsCheckbox = NSButton(checkboxWithTitle: "Confirm before deleting entries", target: nil, action: nil)
    private let installUpdatesSilentlyCheckbox = NSButton(checkboxWithTitle: "Install updates silently", target: nil, action: nil)
    private let updateFrequencyPopup = NSPopUpButton()
    private let sensitiveDataModePopup = NSPopUpButton()
    private var sensitiveDataPresetCheckboxes: [String: NSButton] = [:]
    private let showHotkeyField = HotkeyCaptureField()
    private let toggleHotkeyField = HotkeyCaptureField()
    private let saveCurrentClipboardHotkeyField = HotkeyCaptureField()
    private let passwordField = NSSecureTextField()
    private let ignoredApplicationsView = PreferencesTabTextView()
    private let statusLabel = NSTextField(labelWithString: "")

    init(settings: ClipmanSettings, historyIsEncrypted: Bool, rememberedPasswordExists: Bool, databasePasswordAvailable: Bool) {
        self.settings = settings
        self.historyIsEncrypted = historyIsEncrypted
        self.rememberedPasswordExists = rememberedPasswordExists
        self.databasePasswordAvailable = databasePasswordAvailable
        let window = PreferencesWindow(
            contentRect: NSRect(x: 140, y: 120, width: 760, height: 760),
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

    func update(settings: ClipmanSettings, historyIsEncrypted: Bool, rememberedPasswordExists: Bool, databasePasswordAvailable: Bool) {
        self.settings = settings
        self.historyIsEncrypted = historyIsEncrypted
        self.rememberedPasswordExists = rememberedPasswordExists
        self.databasePasswordAvailable = databasePasswordAvailable
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

        machineNameField.setAccessibilityHelp("Name recorded on new clipboard entries created by this Mac. Existing entries keep their original device name.")
        addRow("Device name", machineNameField)
        addRow("Settings folder", databasePathField, button(title: "Choose...", action: #selector(chooseSettingsFolder)))
        databasePathField.setAccessibilityHelp("Choose the Clipman data/settings folder. Clipman will use clipman-history.clipdb inside that folder.")
        storageModePopup.addItems(withTitles: ["Local or shared folder", "Clipman Server"])
        storageModePopup.setAccessibilityLabel("History storage type")
        addRow("History storage type", storageModePopup)
        serverUrlField.setAccessibilityLabel("Clipman Server host")
        addRow("Server host", serverUrlField)
        serverTokenField.setAccessibilityLabel("Clipman Server token")
        serverTokenField.setAccessibilityHelp("Server authentication token. The token is hidden on screen and saved in this Mac user's Keychain.")
        let importServerButton = button(title: "Import Server File...", action: #selector(importServerConnection))
        importServerButton.setAccessibilityHelp("Import a Clipman Server connection file, review its address, then save preferences.")
        let exportServerButton = button(title: "Export Server File...", action: #selector(exportServerConnection))
        exportServerButton.setAccessibilityHelp("Export the current Clipman Server address and private token to a connection file.")
        let importAuthorityButton = button(title: "Import Authority...", action: #selector(importServerAuthority))
        importAuthorityButton.setAccessibilityHelp("Import a public private-authority certificate for the current HTTPS server host.")
        let removeAuthorityButton = button(title: "Remove Authority", action: #selector(removeServerAuthority))
        removeAuthorityButton.setAccessibilityHelp("Remove the app-specific private certificate authority without changing the server address or token.")
        let serverFileButtons = NSStackView(views: [importServerButton, exportServerButton, importAuthorityButton, removeAuthorityButton])
        serverFileButtons.orientation = .horizontal
        serverFileButtons.spacing = 8
        addRow("Server token", serverTokenField, serverFileButtons)
        serverAuthorityStatus.setAccessibilityLabel("Private certificate authority status")
        grid.addRow(with: [NSGridCell.emptyContentView, serverAuthorityStatus])
        serverAuthorityFingerprint.isEditable = false
        serverAuthorityFingerprint.isSelectable = true
        serverAuthorityFingerprint.isBezeled = true
        serverAuthorityFingerprint.drawsBackground = true
        serverAuthorityFingerprint.setAccessibilityLabel("Private certificate authority SHA-256 fingerprint")
        addRow("Authority fingerprint", serverAuthorityFingerprint)
        addRow("Show history hotkey", showHotkeyField)
        addRow("Toggle monitoring hotkey", toggleHotkeyField)
        addRow("Save current clipboard hotkey, optional", saveCurrentClipboardHotkeyField)
        addRow("History password", passwordField)
        rememberPasswordCheckbox.setAccessibilityLabel("Remember history password in Keychain")
        rememberPasswordCheckbox.setAccessibilityHelp("When checked, Clipman stores the history password in this Mac user's Keychain. When unchecked, Clipman asks for the password each app session and keeps it only in memory.")
        grid.addRow(with: [NSGridCell.emptyContentView, rememberPasswordCheckbox])
        addIgnoredApplicationsRow(to: grid)
        showHotkeyField.hotkeyDelegate = self
        toggleHotkeyField.hotkeyDelegate = self
        saveCurrentClipboardHotkeyField.hotkeyDelegate = self

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

        captureClipboardOnStartupCheckbox.target = nil
        captureClipboardOnStartupCheckbox.action = nil
        captureClipboardOnStartupCheckbox.setAccessibilityLabel("Add current clipboard item to Clipman on start")
        captureClipboardOnStartupCheckbox.setAccessibilityHelp("When checked, Clipman tries to add the current Mac clipboard item to history once when Clipman starts. This is off by default and still follows monitoring, ignored application, concealed pasteboard, and sensitive data settings.")
        grid.addRow(with: [NSGridCell.emptyContentView, captureClipboardOnStartupCheckbox])

        autoCopyRemoteCheckbox.target = nil
        autoCopyRemoteCheckbox.action = nil
        autoCopyRemoteCheckbox.setAccessibilityLabel("Copy latest remote text to this Mac clipboard")
        autoCopyRemoteCheckbox.setAccessibilityHelp("When enabled, new text copied on another device sharing this database is placed on this Mac clipboard. This is off by default.")
        grid.addRow(with: [NSGridCell.emptyContentView, autoCopyRemoteCheckbox])

        pasteAfterEnterCheckbox.target = nil
        pasteAfterEnterCheckbox.action = nil
        pasteAfterEnterCheckbox.setAccessibilityLabel("After Enter, paste into the previous application")
        pasteAfterEnterCheckbox.setAccessibilityHelp("When checked, pressing Enter on a Text or Links history entry copies it, closes Clipman, returns to the previously active application, and pastes it. macOS will ask for permission to let Clipman send the paste command. This is off by default.")
        grid.addRow(with: [NSGridCell.emptyContentView, pasteAfterEnterCheckbox])

        dynamicHistoryModeCheckbox.target = nil
        dynamicHistoryModeCheckbox.action = nil
        dynamicHistoryModeCheckbox.setAccessibilityLabel("Open history to the most recent clipboard type")
        dynamicHistoryModeCheckbox.setAccessibilityHelp("When checked, opening history selects Text, Links, or Files according to the most recent clipboard data Clipman accepted during this run. This is off by default.")
        grid.addRow(with: [NSGridCell.emptyContentView, dynamicHistoryModeCheckbox])

        linksHistoryCheckbox.target = nil
        linksHistoryCheckbox.action = nil
        linksHistoryCheckbox.setAccessibilityLabel("Show Links history tab")
        linksHistoryCheckbox.setAccessibilityHelp("When checked, copied HTTP and HTTPS links that are the whole clipboard entry also appear in a separate Links history tab. When unchecked, links remain in Text history.")
        grid.addRow(with: [NSGridCell.emptyContentView, linksHistoryCheckbox])

        richTextHistoryCheckbox.target = self
        richTextHistoryCheckbox.action = #selector(richTextHistoryChanged)
        richTextHistoryCheckbox.setAccessibilityLabel("Preserve copied formatting and show Rich Text history")
        richTextHistoryCheckbox.setAccessibilityHelp("When checked, Clipman preserves available HTML and RTF formatting alongside plain text and shows the Rich Text history tab. Enable this before copying formatted content. This is off by default.")
        grid.addRow(with: [NSGridCell.emptyContentView, richTextHistoryCheckbox])

        includeImagesCheckbox.target = self
        includeImagesCheckbox.action = #selector(imageHistorySettingChanged)
        includeImagesCheckbox.setAccessibilityLabel("Include images in Rich Text history")
        includeImagesCheckbox.setAccessibilityHelp(includeImagesEnabledAccessibilityHelp)
        grid.addRow(with: [NSGridCell.emptyContentView, includeImagesCheckbox])

        alsoAddCopiedImageFilesCheckbox.target = nil
        alsoAddCopiedImageFilesCheckbox.action = nil
        alsoAddCopiedImageFilesCheckbox.setAccessibilityLabel("Also add copied PNG and JPEG files to Rich Text history")
        alsoAddCopiedImageFilesCheckbox.setAccessibilityHelp("When checked, copying exactly one local PNG or JPEG file keeps the normal File History event and also adds the image to Rich Text history. This is off by default.")
        grid.addRow(with: [NSGridCell.emptyContentView, alsoAddCopiedImageFilesCheckbox])
        includeImagesPrivacyLabel.textColor = .secondaryLabelColor
        includeImagesPrivacyLabel.setAccessibilityLabel("Image metadata privacy")
        grid.addRow(with: [NSGridCell.emptyContentView, includeImagesPrivacyLabel])

        confirmDeletionsCheckbox.target = nil
        confirmDeletionsCheckbox.action = nil
        confirmDeletionsCheckbox.setAccessibilityLabel("Confirm before deleting entries")
        grid.addRow(with: [NSGridCell.emptyContentView, confirmDeletionsCheckbox])

        updateFrequencyPopup.addItems(withTitles: ["Never", "At startup", "Hourly", "Daily"])
        updateFrequencyPopup.setAccessibilityLabel("Check for updates")
        addRow("Check for updates", updateFrequencyPopup)

        installUpdatesSilentlyCheckbox.target = nil
        installUpdatesSilentlyCheckbox.action = nil
        installUpdatesSilentlyCheckbox.setAccessibilityLabel("Install updates silently")
        installUpdatesSilentlyCheckbox.setAccessibilityHelp("When checked, Clipman installs available Mac updates in the background and relaunches itself.")
        grid.addRow(with: [NSGridCell.emptyContentView, installUpdatesSilentlyCheckbox])

        sensitiveDataModePopup.addItems(withTitles: ["Off", "Exclude from history"])
        sensitiveDataModePopup.setAccessibilityLabel("Sensitive data mode")
        addRow("Sensitive data mode", sensitiveDataModePopup)
        addSensitiveDataPresetsRow(to: grid)

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
        machineNameField.stringValue = settings.deviceName
        databasePathField.stringValue = settingsFolderPath(fromDatabasePath: settings.databasePath)
        storageModePopup.selectItem(withTitle: displayStorageMode(settings.storageMode))
        serverUrlField.stringValue = settings.serverUrl
        serverTokenField.stringValue = settings.serverToken
        updateServerAuthorityStatus()
        monitoringCheckbox.state = settings.monitoringEnabled ? .on : .off
        soundsCheckbox.state = settings.soundsEnabled ? .on : .off
        runAtStartupCheckbox.state = settings.runAtStartup ? .on : .off
        captureClipboardOnStartupCheckbox.state = settings.captureClipboardOnStartup ? .on : .off
        rememberPasswordCheckbox.state = settings.rememberDatabasePassword ? .on : .off
        autoCopyRemoteCheckbox.state = settings.autoCopyLatestRemoteText ? .on : .off
        pasteAfterEnterCheckbox.state = settings.pasteAfterEnter ? .on : .off
        dynamicHistoryModeCheckbox.state = settings.dynamicHistoryMode ? .on : .off
        linksHistoryCheckbox.state = settings.linksHistoryEnabled ? .on : .off
        richTextHistoryCheckbox.state = settings.richTextHistoryEnabled ? .on : .off
        includeImagesCheckbox.state = settings.includeImagesInRichTextHistory ? .on : .off
        alsoAddCopiedImageFilesCheckbox.state = settings.alsoAddCopiedImageFilesToRichTextHistory ? .on : .off
        updateImageHistoryAvailability()
        confirmDeletionsCheckbox.state = settings.confirmDeletions ? .on : .off
        installUpdatesSilentlyCheckbox.state = settings.installUpdatesSilently ? .on : .off
        updateFrequencyPopup.selectItem(withTitle: displayUpdateFrequency(settings.updateCheckFrequency))
        sensitiveDataModePopup.selectItem(withTitle: displaySensitiveDataMode(settings.sensitiveDataMode))
        let sensitiveIds = Set(settings.sensitiveDataPresetIds)
        for (id, checkbox) in sensitiveDataPresetCheckboxes {
            checkbox.state = sensitiveIds.contains(id) ? .on : .off
        }
        showHotkeyField.descriptor = settings.showHistoryHotkey
        toggleHotkeyField.descriptor = settings.toggleMonitoringHotkey
        saveCurrentClipboardHotkeyField.descriptor = settings.saveCurrentClipboardHotkey
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

    @objc private func importServerConnection() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "clpconf") ?? .json]
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard fileSize <= 65_536 else { throw ConnectionConfigError.fileTooLarge }
            let details = try ServerSettingsSanitizer.parseConnectionConfig(Data(contentsOf: url))
            let alert = NSAlert()
            alert.messageText = "Import Clipman Server connection?"
            alert.informativeText = "Server: \(details.address)\(authoritySummary(details.authority))\n\nThe token will remain hidden in preferences. Clipman Server requires a unique history password. Choose Save and Close to apply this connection."
            alert.addButton(withTitle: "Import")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            storageModePopup.selectItem(withTitle: "Clipman Server")
            serverUrlField.stringValue = details.address
            serverTokenField.stringValue = details.token
            if let authority = details.authority {
                settings.serverCaCertPem = authority.pem
                settings.serverCaHost = authority.host
            } else if (try? ServerSettingsSanitizer.parseCertificateAuthority(settings.serverCaCertPem, address: details.address)) == nil {
                settings.serverCaCertPem = ""
                settings.serverCaHost = ""
            }
            updateServerAuthorityStatus()
            statusLabel.stringValue = "Server connection imported. Enter a history password if needed, then choose Save and Close to apply it."
            serverUrlField.window?.makeFirstResponder(databasePasswordAvailable ? serverUrlField : passwordField)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not import server connection"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func exportServerConnection() {
        do {
            let data = try ServerSettingsSanitizer.connectionConfigData(
                address: serverUrlField.stringValue,
                token: serverTokenField.stringValue,
                caCertPEM: settings.serverCaCertPem,
                caHost: settings.serverCaHost
            )
            let alert = NSAlert()
            alert.messageText = "Export Clipman Server connection?"
            alert.informativeText = "This file contains the private Clipman Server token. Anyone with the file can connect to that server. Save it only somewhere you trust, then delete it or move it to a password manager after configuring your devices."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Export")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "clpconf") ?? .json]
            panel.nameFieldStringValue = "clipman-server-connection.clpconf"
            panel.canCreateDirectories = true
            panel.prompt = "Export"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            statusLabel.stringValue = "The Clipman Server connection file was exported."
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not export server connection"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func importServerAuthority() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.data]
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard fileSize <= 32 * 1024 else { throw ConnectionConfigError.authorityTooLarge }
            let pem = try String(contentsOf: url, encoding: .utf8)
            guard let authority = try ServerSettingsSanitizer.parseCertificateAuthority(pem, address: serverUrlField.stringValue) else {
                throw ConnectionConfigError.invalidAuthority
            }
            let alert = NSAlert()
            alert.messageText = "Import private authority for this server?"
            alert.informativeText = "Host: \(authority.host)\nSubject: \(authority.subject)\nExpires: \(authority.expires.formatted(date: .long, time: .omitted))\nSHA-256 fingerprint: \(authority.fingerprint)\n\nClipman will trust this authority only for the displayed server host."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Import")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            settings.serverCaCertPem = authority.pem
            settings.serverCaHost = authority.host
            updateServerAuthorityStatus()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not import private authority"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func removeServerAuthority() {
        guard !settings.serverCaCertPem.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Remove private certificate authority?"
        alert.informativeText = "A private-CA server will stop synchronizing unless its authority is trusted by macOS or a new CA-bearing connection file is imported."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        settings.serverCaCertPem = ""
        settings.serverCaHost = ""
        updateServerAuthorityStatus()
    }

    private func updateServerAuthorityStatus() {
        guard !settings.serverCaCertPem.isEmpty else {
            serverAuthorityStatus.stringValue = "Private certificate authority: Not configured"
            serverAuthorityFingerprint.stringValue = ""
            return
        }
        do {
            guard let authority = try ServerSettingsSanitizer.parseCertificateAuthority(settings.serverCaCertPem, address: serverUrlField.stringValue) else {
                throw ConnectionConfigError.invalidAuthority
            }
            let state = authority.expires <= Date().addingTimeInterval(30 * 24 * 60 * 60) ? "Expires soon" : "Configured for \(authority.host)"
            serverAuthorityStatus.stringValue = "Private certificate authority: \(state); subject: \(authority.subject); expires: \(authority.expires.formatted(date: .long, time: .omitted))"
            serverAuthorityFingerprint.stringValue = authority.fingerprint
        } catch {
            serverAuthorityStatus.stringValue = "Private certificate authority: \(error.localizedDescription)"
            serverAuthorityFingerprint.stringValue = ""
        }
    }

    private func authoritySummary(_ authority: ServerCertificateAuthority?) -> String {
        guard let authority else { return "" }
        return "\n\nThis file configures a private certificate authority only for \(authority.host).\nSubject: \(authority.subject)\nAuthority expires: \(authority.expires.formatted(date: .long, time: .omitted))\nSHA-256 fingerprint: \(authority.fingerprint)"
    }

    @objc private func richTextHistoryChanged() {
        updateImageHistoryAvailability()
    }

    @objc private func imageHistorySettingChanged() {
        updateImageHistoryAvailability()
    }

    private func updateImageHistoryAvailability() {
        let enabled = richTextHistoryCheckbox.state == .on
        if !enabled {
            includeImagesCheckbox.state = .off
        }
        includeImagesCheckbox.isEnabled = enabled
        includeImagesCheckbox.setAccessibilityHelp(enabled
            ? includeImagesEnabledAccessibilityHelp
            : "Enable Preserve copied formatting and show Rich Text history before including images.")
        let automaticFileCaptureEnabled = enabled && includeImagesCheckbox.state == .on
        if !automaticFileCaptureEnabled {
            alsoAddCopiedImageFilesCheckbox.state = .off
        }
        alsoAddCopiedImageFilesCheckbox.isEnabled = automaticFileCaptureEnabled
        alsoAddCopiedImageFilesCheckbox.setAccessibilityHelp(automaticFileCaptureEnabled
            ? "When checked, copying exactly one local PNG or JPEG file keeps the normal File History event and also adds the image to Rich Text history. This is off by default."
            : "Enable Rich Text history and Include images in Rich Text history before also adding copied image files.")
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
        let saveHotkeyText = saveCurrentClipboardHotkeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let saveCurrentClipboardHotkey: HotkeyDescriptor?
        if saveHotkeyText.isEmpty {
            saveCurrentClipboardHotkey = nil
        } else if let captured = saveCurrentClipboardHotkeyField.descriptor ?? HotkeyDescriptor.parse(saveHotkeyText), captured.isValid {
            saveCurrentClipboardHotkey = captured
        } else {
            statusLabel.stringValue = "Save current clipboard hotkey must be blank or use a valid global hotkey."
            return
        }
        guard saveCurrentClipboardHotkey != show, saveCurrentClipboardHotkey != toggle else {
            statusLabel.stringValue = "Save current clipboard must use a different hotkey from Show History and Toggle Monitoring."
            return
        }
        guard saveCurrentClipboardHotkey == nil || !settings.quickCopyHotkeys.values.contains(saveCurrentClipboardHotkey!) else {
            statusLabel.stringValue = "Save current clipboard cannot use a hotkey already assigned to Quick Paste."
            return
        }
        guard confirmSingleModifierHotkeys(show: show, toggle: toggle, saveCurrentClipboard: saveCurrentClipboardHotkey) else {
            return
        }
        let selectedStorageMode = storedStorageMode(storageModePopup.titleOfSelectedItem ?? "")
        let enteredPassword = passwordField.stringValue
        guard selectedStorageMode != "Server" || !enteredPassword.isEmpty || databasePasswordAvailable else {
            statusLabel.stringValue = "Clipman Server requires a unique history password before the connection can be saved."
            passwordField.window?.makeFirstResponder(passwordField)
            return
        }
        let normalizedServerURL = ServerSettingsSanitizer.cleanURL(serverUrlField.stringValue)
        if !settings.serverCaCertPem.isEmpty {
            do {
                guard let authority = try ServerSettingsSanitizer.parseCertificateAuthority(settings.serverCaCertPem, address: normalizedServerURL),
                      settings.serverCaHost.isEmpty || authority.host.caseInsensitiveCompare(settings.serverCaHost) == .orderedSame
                else { throw ConnectionConfigError.authorityHostMismatch }
                settings.serverCaCertPem = authority.pem
                settings.serverCaHost = authority.host
            } catch {
                let alert = NSAlert()
                alert.messageText = "Remove private authority and save changed server?"
                alert.informativeText = "The server host or connection scheme no longer matches the configured private authority. Remove that authority and save the new server address?"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Remove and Save")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                settings.serverCaCertPem = ""
                settings.serverCaHost = ""
            }
        }
        settings.databasePath = normalizedDatabasePath(databasePathField.stringValue)
        let requestedMachineName = machineNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedMachineName.isEmpty else {
            statusLabel.stringValue = "Device name cannot be blank."
            machineNameField.window?.makeFirstResponder(machineNameField)
            return
        }
        settings.deviceName = requestedMachineName
        settings.storageMode = selectedStorageMode
        settings.serverUrl = normalizedServerURL
        settings.serverToken = ServerSettingsSanitizer.cleanToken(serverTokenField.stringValue)
        serverUrlField.stringValue = settings.serverUrl
        serverTokenField.stringValue = settings.serverToken
        settings.monitoringEnabled = monitoringCheckbox.state == .on
        settings.soundsEnabled = soundsCheckbox.state == .on
        settings.runAtStartup = runAtStartupCheckbox.state == .on
        settings.captureClipboardOnStartup = captureClipboardOnStartupCheckbox.state == .on
        settings.rememberDatabasePassword = rememberPasswordCheckbox.state == .on
        settings.autoCopyLatestRemoteText = autoCopyRemoteCheckbox.state == .on
        settings.pasteAfterEnter = pasteAfterEnterCheckbox.state == .on
        settings.dynamicHistoryMode = dynamicHistoryModeCheckbox.state == .on
        settings.linksHistoryEnabled = linksHistoryCheckbox.state == .on
        settings.richTextHistoryEnabled = richTextHistoryCheckbox.state == .on
        settings.includeImagesInRichTextHistory = settings.richTextHistoryEnabled && includeImagesCheckbox.state == .on
        settings.alsoAddCopiedImageFilesToRichTextHistory = EmbeddedImageFileImport.automaticCaptureEnabled(
            richTextHistoryEnabled: settings.richTextHistoryEnabled,
            includeImagesEnabled: settings.includeImagesInRichTextHistory,
            alsoAddCopiedImageFilesEnabled: alsoAddCopiedImageFilesCheckbox.state == .on
        )
        settings.confirmDeletions = confirmDeletionsCheckbox.state == .on
        settings.lastSelectedHistoryTab = HistoryTabID.normalize(settings.lastSelectedHistoryTab, linksEnabled: settings.linksHistoryEnabled, richTextEnabled: settings.richTextHistoryEnabled)
        settings.installUpdatesSilently = installUpdatesSilentlyCheckbox.state == .on
        settings.updateCheckFrequency = storedUpdateFrequency(updateFrequencyPopup.titleOfSelectedItem ?? "Never")
        settings.sensitiveDataMode = storedSensitiveDataMode(sensitiveDataModePopup.titleOfSelectedItem ?? "Off")
        settings.sensitiveDataPresetIds = sensitiveDataPresetCheckboxes
            .filter { $0.value.state == .on }
            .map(\.key)
            .sorted()
        settings.showHistoryHotkey = show
        settings.toggleMonitoringHotkey = toggle
        settings.saveCurrentClipboardHotkey = saveCurrentClipboardHotkey
        settings.ignoredApplications = normalizedIgnoredApplications(ignoredApplicationsView.string)
        let password = enteredPassword.isEmpty ? nil : enteredPassword
        guard preferencesDelegate?.preferencesWindow(self, didUpdate: settings, passwordToSave: password) != false else {
            return
        }
        statusLabel.stringValue = "Preferences saved."
        window?.close()
    }

    private func confirmSingleModifierHotkeys(show: HotkeyDescriptor, toggle: HotkeyDescriptor, saveCurrentClipboard: HotkeyDescriptor?) -> Bool {
        guard show.usesSingleModifier || toggle.usesSingleModifier || saveCurrentClipboard?.usesSingleModifier == true else {
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

    private func displayStorageMode(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("Server") == .orderedSame
            ? "Clipman Server"
            : "Local or shared folder"
    }

    private func storedStorageMode(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("Clipman Server") == .orderedSame ||
            value.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("Server") == .orderedSame
            ? "Server"
            : "File"
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

    private func displaySensitiveDataMode(_ value: String) -> String {
        SensitiveDataExclusion.normalizeMode(value) == SensitiveDataExclusion.modeExclude ? "Exclude from history" : "Off"
    }

    private func storedSensitiveDataMode(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("Exclude from history") == .orderedSame
            ? SensitiveDataExclusion.modeExclude
            : SensitiveDataExclusion.modeOff
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

    private func addSensitiveDataPresetsRow(to grid: NSGridView) {
        let labelView = NSTextField(labelWithString: "Exclusion presets")
        labelView.alignment = .right
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        sensitiveDataPresetCheckboxes.removeAll()
        for preset in SensitiveDataExclusion.builtInPresets {
            let checkbox = NSButton(checkboxWithTitle: preset.name, target: nil, action: nil)
            checkbox.setAccessibilityLabel(preset.name)
            checkbox.setAccessibilityHelp("When checked, this preset is excluded from automatic clipboard history if sensitive data mode is set to Exclude from history.")
            sensitiveDataPresetCheckboxes[preset.id] = checkbox
            stack.addArrangedSubview(checkbox)
        }
        grid.addRow(with: [labelView, stack])

        let note = NSTextField(labelWithString: "Sensitive data exclusions apply only to automatic clipboard capture. They do not alter the Mac clipboard, existing history, explicit imports, or entries copied from Clipman. Presets are off by default.")
        note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byWordWrapping
        note.maximumNumberOfLines = 3
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
