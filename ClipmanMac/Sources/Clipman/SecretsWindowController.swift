import AppKit
import Carbon
import ClipmanCore

@MainActor
protocol SecretsWindowControllerDelegate: AnyObject {
    func secretsWindow(_ controller: SecretsWindowController, quickPaste secret: SecretEntry)
    func secretsWindowDidChangeSecrets(_ controller: SecretsWindowController)
}

@MainActor
final class SecretsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    weak var secretsDelegate: SecretsWindowControllerDelegate?

    private let store: SecretStore
    private let table = NSTableView()
    private var entries: [SecretEntry] = []

    init(store: SecretStore) {
        self.store = store
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Clipman Secrets"
        window.center()
        super.init(window: window)
        buildUI()
        refresh(selectID: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        refresh(selectID: selectedEntry()?.Id)
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("secret")))
        table.tableColumns.first?.title = "Secret"
        table.tableColumns.first?.width = 560
        table.headerView = nil
        table.delegate = self
        table.dataSource = self
        table.usesAlternatingRowBackgroundColors = true
        table.setAccessibilityLabel("Secrets")
        table.setAccessibilityHelp("Saved secret names. Values are hidden. Press Return to quick paste, F2 for properties, Insert to add, or Delete to remove.")
        table.target = self
        table.doubleAction = #selector(quickPasteSelected(_:))

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        content.addSubview(scroll)

        let buttons = NSStackView()
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8
        buttons.distribution = .gravityAreas

        let quickPaste = NSButton(title: "Quick Paste", target: self, action: #selector(quickPasteSelected(_:)))
        let add = NSButton(title: "Add", target: self, action: #selector(addSecret(_:)))
        let properties = NSButton(title: "Properties", target: self, action: #selector(editSelected(_:)))
        let delete = NSButton(title: "Delete", target: self, action: #selector(deleteSelected(_:)))
        let close = NSButton(title: "Close", target: self, action: #selector(closeWindow(_:)))
        for button in [quickPaste, add, properties, delete, close] {
            buttons.addArrangedSubview(button)
        }
        content.addSubview(buttons)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -10),

            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            buttons.heightAnchor.constraint(equalToConstant: 32)
        ])
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        entries.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("SecretCell")
        let field = (tableView.makeView(withIdentifier: id, owner: self) as? NSTextField) ?? NSTextField(labelWithString: "")
        field.identifier = id
        field.stringValue = displayText(for: entries[row])
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter:
            quickPasteSelected(nil)
        case kVK_F2:
            editSelected(nil)
        case kVK_Delete, kVK_ForwardDelete:
            deleteSelected(nil)
        case kVK_Escape:
            close()
        case kVK_Help:
            addSecret(nil)
        default:
            super.keyDown(with: event)
        }
    }

    @objc private func closeWindow(_ sender: Any?) {
        close()
    }

    @objc private func quickPasteSelected(_ sender: Any?) {
        guard let entry = selectedEntry() else { return }
        secretsDelegate?.secretsWindow(self, quickPaste: entry)
        close()
    }

    @objc private func addSecret(_ sender: Any?) {
        var entry = SecretEntry()
        guard edit(entry: &entry, isNew: true) else { return }
        save(entry)
    }

    @objc private func editSelected(_ sender: Any?) {
        guard var entry = selectedEntry() else { return }
        guard edit(entry: &entry, isNew: false) else { return }
        save(entry)
    }

    @objc private func deleteSelected(_ sender: Any?) {
        guard let entry = selectedEntry() else { return }
        let alert = NSAlert()
        alert.messageText = "Delete Secret?"
        alert.informativeText = "Delete \(entry.Name.isEmpty ? "the selected secret" : entry.Name)?"
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try store.delete(id: entry.Id)
            secretsDelegate?.secretsWindowDidChangeSecrets(self)
            refresh(selectID: nil)
        } catch {
            showError("Could not delete the selected secret.", error: error)
        }
    }

    private func save(_ entry: SecretEntry) {
        do {
            try store.save(entry)
            secretsDelegate?.secretsWindowDidChangeSecrets(self)
            refresh(selectID: entry.Id)
        } catch {
            showError("Could not save the secret.", error: error)
        }
    }

    private func edit(entry: inout SecretEntry, isNew: Bool) -> Bool {
        let alert = NSAlert()
        alert.messageText = isNew ? "Add Secret" : "Secret Properties"
        alert.informativeText = "Secrets are stored separately from clipboard history. Quick Paste temporarily places the secret on the clipboard, pastes it, then restores the previous clipboard."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let nameField = NSTextField(string: entry.Name)
        nameField.setAccessibilityLabel("Secret name")
        let valueField = NSSecureTextField(string: entry.Value)
        valueField.setAccessibilityLabel("Secret value")
        let confirmField = NSSecureTextField(string: entry.Value)
        confirmField.setAccessibilityLabel("Confirm secret value")
        let hotkeyField = HotkeyCaptureField()
        hotkeyField.descriptor = HotkeyDescriptor.parse(entry.Hotkey)
        hotkeyField.setAccessibilityLabel("Quick Paste hotkey")

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Name"), nameField],
            [NSTextField(labelWithString: "Secret"), valueField],
            [NSTextField(labelWithString: "Confirm"), confirmField],
            [NSTextField(labelWithString: "Quick Paste hotkey"), hotkeyField]
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 360
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.frame = NSRect(x: 0, y: 0, width: 500, height: 135)
        alert.accessoryView = grid

        while true {
            guard runModalWithTextEditingShortcuts(alert) == .alertFirstButtonReturn else { return false }
            let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                showError("Type a name for this secret.")
                continue
            }
            guard valueField.stringValue == confirmField.stringValue else {
                showError("The secret and confirmation do not match.")
                continue
            }
            if let descriptor = hotkeyField.descriptor ?? HotkeyDescriptor.parse(hotkeyField.stringValue),
               !descriptor.isValid {
                showError("Quick Paste needs a valid hotkey.")
                continue
            }
            entry.Name = name
            entry.Value = valueField.stringValue
            entry.Hotkey = (hotkeyField.descriptor ?? HotkeyDescriptor.parse(hotkeyField.stringValue))?.description ?? ""
            return true
        }
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

    private func refresh(selectID: String?) {
        entries = store.entries()
        table.reloadData()
        var index = 0
        if let selectID, let found = entries.firstIndex(where: { $0.Id == selectID }) {
            index = found
        }
        if !entries.isEmpty {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            table.scrollRowToVisible(index)
        }
    }

    private func selectedEntry() -> SecretEntry? {
        let row = table.selectedRow
        guard row >= 0, row < entries.count else { return nil }
        return entries[row]
    }

    private func displayText(for entry: SecretEntry) -> String {
        let name = entry.Name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Unnamed secret" : entry.Name
        guard !entry.Hotkey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return name }
        return "\(name); Quick Paste: \(entry.Hotkey)"
    }

    private func showError(_ message: String, error: Error? = nil) {
        let alert = NSAlert()
        alert.messageText = "Clipman Secrets"
        alert.informativeText = error == nil ? message : "\(message)\n\n\(error!.localizedDescription)"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
