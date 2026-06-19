import AppKit
import UniformTypeIdentifiers
import Carbon

@MainActor
protocol PreferencesWindowControllerDelegate: AnyObject {
    func preferencesWindow(_ controller: PreferencesWindowController, didUpdate settings: ClipmanSettings, passwordToSave: String?)
}

final class PreferencesWindow: NSWindow {
    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            close()
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "w" {
            close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class PreferencesWindowController: NSWindowController, HotkeyCaptureFieldDelegate {
    weak var preferencesDelegate: PreferencesWindowControllerDelegate?
    private var settings: ClipmanSettings
    private let databasePathField = NSTextField()
    private let monitoringCheckbox = NSButton(checkboxWithTitle: "Monitoring enabled", target: nil, action: nil)
    private let runAtStartupCheckbox = NSButton(checkboxWithTitle: "Run Clipman at login", target: nil, action: nil)
    private let showHotkeyField = HotkeyCaptureField()
    private let toggleHotkeyField = HotkeyCaptureField()
    private let passwordField = NSSecureTextField()
    private let statusLabel = NSTextField(labelWithString: "")

    init(settings: ClipmanSettings) {
        self.settings = settings
        let window = PreferencesWindow(
            contentRect: NSRect(x: 140, y: 140, width: 620, height: 380),
            styleMask: [.titled, .closable],
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

    func update(settings: ClipmanSettings) {
        self.settings = settings
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
        addRow("Show history hotkey", showHotkeyField)
        addRow("Toggle monitoring hotkey", toggleHotkeyField)
        addRow("History password", passwordField)
        showHotkeyField.hotkeyDelegate = self
        toggleHotkeyField.hotkeyDelegate = self

        monitoringCheckbox.target = nil
        monitoringCheckbox.action = nil
        monitoringCheckbox.setAccessibilityLabel("Monitoring enabled")
        grid.addRow(with: [NSGridCell.emptyContentView, monitoringCheckbox])

        runAtStartupCheckbox.target = nil
        runAtStartupCheckbox.action = nil
        runAtStartupCheckbox.setAccessibilityLabel("Run Clipman at login")
        grid.addRow(with: [NSGridCell.emptyContentView, runAtStartupCheckbox])

        let saveButton = button(title: "Save", action: #selector(saveClicked))
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
        databasePathField.stringValue = settings.databasePath
        monitoringCheckbox.state = settings.monitoringEnabled ? .on : .off
        runAtStartupCheckbox.state = settings.runAtStartup ? .on : .off
        showHotkeyField.descriptor = settings.showHistoryHotkey
        toggleHotkeyField.descriptor = settings.toggleMonitoringHotkey
        passwordField.stringValue = ""
        statusLabel.stringValue = "Leave password blank to keep the saved Keychain password."
    }

    @objc private func chooseSettingsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            databasePathField.stringValue = url.appendingPathComponent("clipman-history.clipdb").path
        }
    }

    @objc private func saveClicked() {
        guard let show = showHotkeyField.descriptor ?? HotkeyDescriptor.parse(showHotkeyField.stringValue), show.isValid else {
            statusLabel.stringValue = "Show history hotkey must use at least two modifiers, or one modifier with F1-F12. Escape, Tab, Backspace, Return, and Space are not available."
            return
        }
        guard let toggle = toggleHotkeyField.descriptor ?? HotkeyDescriptor.parse(toggleHotkeyField.stringValue), toggle.isValid else {
            statusLabel.stringValue = "Toggle monitoring hotkey must use at least two modifiers, or one modifier with F1-F12. Escape, Tab, Backspace, Return, and Space are not available."
            return
        }
        guard show != toggle else {
            statusLabel.stringValue = "Show history and toggle monitoring cannot use the same hotkey."
            return
        }
        settings.databasePath = normalizedDatabasePath(databasePathField.stringValue)
        settings.monitoringEnabled = monitoringCheckbox.state == .on
        settings.runAtStartup = runAtStartupCheckbox.state == .on
        settings.showHistoryHotkey = show
        settings.toggleMonitoringHotkey = toggle
        let password = passwordField.stringValue.isEmpty ? nil : passwordField.stringValue
        preferencesDelegate?.preferencesWindow(self, didUpdate: settings, passwordToSave: password)
        statusLabel.stringValue = "Preferences saved."
        window?.close()
    }

    func hotkeyCaptureFieldDidChange(_ field: HotkeyCaptureField) {
        statusLabel.stringValue = "Captured \(field.stringValue)."
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
}
