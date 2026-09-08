import AppKit
import Carbon
import ClipmanCore

/// The sync rules editor of `sync-rules-spec.md` sections 3 and 4: the global
/// switch, the channel list with its routes, and the per-device subscription
/// list. A document written by a newer Clipman is shown but never edited here.
@MainActor
final class SyncRulesWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let store: ClipStore
    private var document = SyncRulesDocument()
    private var readOnly = false
    private var deviceName = ""

    private let enabledCheckbox = NSButton(checkboxWithTitle: "Enable sync rules", target: nil, action: nil)
    private let warningLabel = NSTextField(wrappingLabelWithString: syncRulesGuidanceText)
    private let channelsTable = NSTableView()
    private let devicesTable = NSTableView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let addChannelButton = NSButton(title: "Add Channel", target: nil, action: nil)
    private let editChannelButton = NSButton(title: "Edit Channel", target: nil, action: nil)
    private let removeChannelButton = NSButton(title: "Remove Channel", target: nil, action: nil)
    private let editSubscriptionsButton = NSButton(title: "Edit Subscriptions", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save and Close", target: nil, action: nil)

    private let channelNameColumn = NSUserInterfaceItemIdentifier("channelName")
    private let channelRuleColumn = NSUserInterfaceItemIdentifier("channelRule")
    private let deviceNameColumn = NSUserInterfaceItemIdentifier("deviceName")
    private let deviceChannelsColumn = NSUserInterfaceItemIdentifier("deviceChannels")

    init(store: ClipStore) {
        self.store = store
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Clipman Sync Rules"
        window.center()
        super.init(window: window)
        buildUI()
        reload()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        reload()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Reads the document the store currently has in effect, so the editor never
    /// starts from a stale copy after a poll merged another device's edit.
    func reload() {
        deviceName = store.syncRulesDeviceName()
        readOnly = store.syncRulesReadOnly()
        document = store.getSyncRules() ?? SyncRulesDocument(
            Clipman: SyncRuleEngine.documentKind,
            Version: SyncRuleEngine.currentVersion,
            Enabled: false,
            UpdatedUnixMs: 0,
            UpdatedBy: deviceName
        )
        // Show this Mac in the device list even before the registry adds it, so
        // its subscriptions can be edited from here (spec section 4, Registry
        // behavior does the same on the next successful sync).
        let normalizedDeviceName = SyncRuleEngine.normalized(deviceName)
        if !readOnly,
           !normalizedDeviceName.isEmpty,
           !document.Devices.contains(where: { SyncRuleEngine.normalized($0.Name) == normalizedDeviceName }) {
            document.Devices.append(SyncDevice(Name: deviceName, Channels: ["*"]))
        }
        enabledCheckbox.state = document.Enabled ? .on : .off
        statusLabel.stringValue = readOnly
            ? "These sync rules were written by a newer version of Clipman. They are shown here but cannot be changed on this Mac."
            : "This Mac is called \"\(deviceName)\" in these rules."
        channelsTable.reloadData()
        devicesTable.reloadData()
        updateAvailability()
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        enabledCheckbox.target = self
        enabledCheckbox.action = #selector(enabledChanged(_:))
        enabledCheckbox.setAccessibilityLabel("Enable sync rules")
        enabledCheckbox.setAccessibilityHelp("When unchecked, every device behaves exactly as it would without sync rules, even if channels are defined. This is the instant global off switch.")

        warningLabel.textColor = .secondaryLabelColor
        warningLabel.maximumNumberOfLines = 3
        warningLabel.setAccessibilityLabel("Sync rules guidance")

        configure(
            table: channelsTable,
            columns: [(channelNameColumn, "Channel", 200), (channelRuleColumn, "Rule", 420)],
            label: "Sync channels",
            help: "Named partitions of the shared history. The first channel whose rule matches an entry wins; entries that match nothing stay in the main history."
        )
        configure(
            table: devicesTable,
            columns: [(deviceNameColumn, "Device", 200), (deviceChannelsColumn, "Downloads", 420)],
            label: "Devices",
            help: "Which channels each device downloads. The main history is always downloaded. A device that is not listed downloads everything."
        )
        channelsTable.target = self
        channelsTable.doubleAction = #selector(editChannel(_:))
        devicesTable.target = self
        devicesTable.doubleAction = #selector(editSubscriptions(_:))

        addChannelButton.target = self
        addChannelButton.action = #selector(addChannel(_:))
        addChannelButton.setAccessibilityLabel("Add channel")
        editChannelButton.target = self
        editChannelButton.action = #selector(editChannel(_:))
        editChannelButton.setAccessibilityLabel("Edit channel")
        removeChannelButton.target = self
        removeChannelButton.action = #selector(removeChannel(_:))
        removeChannelButton.setAccessibilityLabel("Remove channel")
        editSubscriptionsButton.target = self
        editSubscriptionsButton.action = #selector(editSubscriptions(_:))
        editSubscriptionsButton.setAccessibilityLabel("Edit subscriptions")
        saveButton.target = self
        saveButton.action = #selector(saveAndClose(_:))
        saveButton.setAccessibilityLabel("Save sync rules and close")
        let closeButton = NSButton(title: "Close", target: self, action: #selector(closeWindow(_:)))
        closeButton.setAccessibilityLabel("Close without saving")
        for button in [addChannelButton, editChannelButton, removeChannelButton, editSubscriptionsButton, saveButton, closeButton] {
            button.bezelStyle = .rounded
        }

        let channelsHeading = heading("Channels")
        let devicesHeading = heading("Devices")
        let channelsScroll = scrollView(for: channelsTable)
        let devicesScroll = scrollView(for: devicesTable)

        let channelButtons = NSStackView(views: [addChannelButton, editChannelButton, removeChannelButton])
        channelButtons.orientation = .horizontal
        channelButtons.spacing = 8
        let deviceButtons = NSStackView(views: [editSubscriptionsButton])
        deviceButtons.orientation = .horizontal
        deviceButtons.spacing = 8
        let bottomButtons = NSStackView(views: [saveButton, closeButton])
        bottomButtons.orientation = .horizontal
        bottomButtons.spacing = 8

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 3
        statusLabel.setAccessibilityLabel("Sync rules status")

        let stack = NSStackView(views: [
            enabledCheckbox,
            warningLabel,
            channelsHeading,
            channelsScroll,
            channelButtons,
            devicesHeading,
            devicesScroll,
            deviceButtons,
            statusLabel,
            bottomButtons
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            warningLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            channelsScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            devicesScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            channelsScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            devicesScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140)
        ])
    }

    private func heading(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        return field
    }

    private func scrollView(for table: NSTableView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        return scroll
    }

    private func configure(
        table: NSTableView,
        columns: [(NSUserInterfaceItemIdentifier, String, CGFloat)],
        label: String,
        help: String
    ) {
        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: identifier)
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.headerView = NSTableHeaderView()
        table.delegate = self
        table.dataSource = self
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.setAccessibilityLabel(label)
        table.setAccessibilityHelp(help)
    }

    // MARK: - Table data

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === channelsTable ? document.Channels.count : document.Devices.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn else { return nil }
        let identifier = tableColumn.identifier
        let field = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField)
            ?? NSTextField(labelWithString: "")
        field.identifier = identifier
        field.lineBreakMode = .byTruncatingTail
        field.stringValue = cellText(tableView: tableView, identifier: identifier, row: row)
        field.setAccessibilityLabel("\(tableColumn.title): \(field.stringValue)")
        return field
    }

    private func cellText(tableView: NSTableView, identifier: NSUserInterfaceItemIdentifier, row: Int) -> String {
        if tableView === channelsTable {
            guard row >= 0, row < document.Channels.count else { return "" }
            let channel = document.Channels[row]
            return identifier == channelNameColumn ? channel.Name : routeSummary(channel.Route)
        }
        guard row >= 0, row < document.Devices.count else { return "" }
        let device = document.Devices[row]
        return identifier == deviceNameColumn ? device.Name : subscriptionSummary(device)
    }

    private func routeSummary(_ route: SyncRoute) -> String {
        var parts: [String] = []
        if let groups = route.Groups, !groups.isEmpty {
            parts.append("Groups: " + groups.joined(separator: ", "))
        }
        if let devices = route.SourceDevices, !devices.isEmpty {
            parts.append("Source devices: " + devices.joined(separator: ", "))
        }
        if let kind = route.Kind, !kind.isEmpty {
            parts.append(kind == SyncRuleEngine.richTextImagesKind
                ? "Rich text containing images"
                : "Condition this version does not understand: \(kind)")
        }
        guard !parts.isEmpty else { return "No condition, so this channel never matches" }
        return parts.joined(separator: "; and ")
    }

    private func subscriptionSummary(_ device: SyncDevice) -> String {
        if device.Channels.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "*" }) {
            return "All channels"
        }
        guard !device.Channels.isEmpty else { return "Main history only" }
        return device.Channels.joined(separator: ", ")
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateAvailability()
    }

    private func updateAvailability() {
        let editable = !readOnly
        enabledCheckbox.isEnabled = editable
        addChannelButton.isEnabled = editable
        editChannelButton.isEnabled = editable && channelsTable.selectedRow >= 0
        removeChannelButton.isEnabled = editable && channelsTable.selectedRow >= 0
        editSubscriptionsButton.isEnabled = editable && devicesTable.selectedRow >= 0
        saveButton.isEnabled = editable
    }

    // MARK: - Actions

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Escape:
            close()
        default:
            super.keyDown(with: event)
        }
    }

    @objc private func closeWindow(_ sender: Any?) {
        close()
    }

    @objc private func enabledChanged(_ sender: Any?) {
        document.Enabled = enabledCheckbox.state == .on
    }

    @objc private func addChannel(_ sender: Any?) {
        guard !readOnly else { return }
        var channel = SyncChannel()
        guard runChannelSheet(&channel, replacing: nil) else { return }
        document.Channels.append(channel)
        channelsTable.reloadData()
        select(row: document.Channels.count - 1, in: channelsTable)
        statusLabel.stringValue = "Added the \(channel.Name) channel. Choose Save and Close to apply it."
    }

    @objc private func editChannel(_ sender: Any?) {
        guard !readOnly else { return }
        let row = channelsTable.selectedRow
        guard row >= 0, row < document.Channels.count else { return }
        var channel = document.Channels[row]
        let previousKey = SyncRuleEngine.channelKey(channel.Name)
        guard runChannelSheet(&channel, replacing: row) else { return }
        document.Channels[row] = channel
        let newKey = SyncRuleEngine.channelKey(channel.Name)
        if previousKey != newKey {
            renameSubscriptions(from: previousKey, to: newKey)
        }
        channelsTable.reloadData()
        devicesTable.reloadData()
        select(row: row, in: channelsTable)
    }

    @objc private func removeChannel(_ sender: Any?) {
        guard !readOnly else { return }
        let row = channelsTable.selectedRow
        guard row >= 0, row < document.Channels.count else { return }
        let channel = document.Channels[row]

        let alert = NSAlert()
        alert.messageText = "Remove the \(channel.Name) channel?"
        alert.informativeText = "Entries in this channel will move to the next matching channel or to the main history. No entries are deleted."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let key = SyncRuleEngine.channelKey(channel.Name)
        document.Channels.remove(at: row)
        removeSubscriptions(to: key)
        channelsTable.reloadData()
        devicesTable.reloadData()
        select(row: min(row, document.Channels.count - 1), in: channelsTable)
        statusLabel.stringValue = "Removed the \(channel.Name) channel. Choose Save and Close to move its entries."
    }

    @objc private func editSubscriptions(_ sender: Any?) {
        guard !readOnly else { return }
        let row = devicesTable.selectedRow
        guard row >= 0, row < document.Devices.count else { return }
        var device = document.Devices[row]
        guard runSubscriptionsSheet(&device) else { return }
        document.Devices[row] = device
        devicesTable.reloadData()
        select(row: row, in: devicesTable)
    }

    @objc private func saveAndClose(_ sender: Any?) {
        guard !readOnly else { return }
        document.Enabled = enabledCheckbox.state == .on
        document.Clipman = SyncRuleEngine.documentKind
        document.Version = SyncRuleEngine.currentVersion
        // Subscriptions are stored as channel keys, and a channel that was
        // renamed or removed during this edit must not leave a dangling
        // reference behind.
        let known = Set(SyncRuleEngine.allChannelKeys(document))
        for index in document.Devices.indices {
            if document.Devices[index].Channels.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "*" }) {
                document.Devices[index].Channels = ["*"]
                continue
            }
            document.Devices[index].Channels = document.Devices[index].Channels
                .map { SyncRuleEngine.normalized($0) }
                .filter { known.contains($0) }
        }
        if let reason = store.setSyncRules(document) {
            statusLabel.stringValue = reason
            NSAccessibility.post(
                element: NSApplication.shared,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: reason,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue
                ]
            )
            return
        }
        close()
    }

    private func select(row: Int, in table: NSTableView) {
        guard row >= 0, row < table.numberOfRows else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
        updateAvailability()
    }

    private func renameSubscriptions(from previousKey: String, to newKey: String) {
        guard !previousKey.isEmpty, !newKey.isEmpty else { return }
        for index in document.Devices.indices {
            document.Devices[index].Channels = document.Devices[index].Channels.map {
                SyncRuleEngine.normalized($0) == previousKey ? newKey : $0
            }
        }
    }

    private func removeSubscriptions(to key: String) {
        guard !key.isEmpty else { return }
        for index in document.Devices.indices {
            document.Devices[index].Channels.removeAll { SyncRuleEngine.normalized($0) == key }
        }
    }

    // MARK: - Sheets

    /// `replacing` is the row the edited channel takes the place of, or nil when
    /// a new channel is being added. It matters because uniqueness has to be
    /// checked against the rest of the document, not against the channel's own
    /// previous name.
    private func runChannelSheet(_ channel: inout SyncChannel, replacing: Int?) -> Bool {
        let alert = NSAlert()
        alert.messageText = replacing == nil ? "Add Sync Channel" : "Edit Sync Channel"
        alert.informativeText = "Conditions are combined: an entry must satisfy every condition you fill in. The first channel whose rule matches wins."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let nameField = NSTextField(string: channel.Name)
        nameField.setAccessibilityLabel("Channel name")
        nameField.setAccessibilityHelp("1 to 32 letters, digits, spaces, dashes or underscores, starting and ending with a letter or digit. The names core, all, pinned and sync-rules are reserved.")
        let groupsField = NSTextField(string: (channel.Route.Groups ?? []).joined(separator: ", "))
        groupsField.setAccessibilityLabel("Groups")
        groupsField.setAccessibilityHelp("Comma-separated group names. Leave blank to ignore the group.")
        let devicesField = NSTextField(string: (channel.Route.SourceDevices ?? []).joined(separator: ", "))
        devicesField.setAccessibilityLabel("Source devices")
        devicesField.setAccessibilityHelp("Comma-separated device names. Leave blank to ignore which device captured the entry.")
        let imagesCheckbox = NSButton(checkboxWithTitle: "Only rich text containing images", target: nil, action: nil)
        imagesCheckbox.state = (channel.Route.Kind ?? "") == SyncRuleEngine.richTextImagesKind ? .on : .off
        imagesCheckbox.setAccessibilityLabel("Only rich text containing images")
        imagesCheckbox.setAccessibilityHelp("When checked, only entries whose formatted text embeds an image match this channel.")

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Name"), nameField],
            [NSTextField(labelWithString: "Groups"), groupsField],
            [NSTextField(labelWithString: "Source devices"), devicesField],
            [NSGridCell.emptyContentView, imagesCheckbox]
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 380
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.frame = NSRect(x: 0, y: 0, width: 520, height: 140)
        alert.accessoryView = grid
        alert.window.initialFirstResponder = nameField

        while true {
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            let candidate = SyncChannel(
                Name: nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                Route: SyncRoute(
                    Groups: splitList(groupsField.stringValue),
                    SourceDevices: splitList(devicesField.stringValue),
                    Kind: imagesCheckbox.state == .on ? SyncRuleEngine.richTextImagesKind : nil
                )
            )
            var probe = document
            if let replacing, replacing >= 0, replacing < probe.Channels.count {
                probe.Channels[replacing] = candidate
            } else {
                probe.Channels.append(candidate)
            }
            // Device references are checked separately once the channel list is
            // settled, so they must not fail this in-progress edit.
            probe.Devices = []
            if let reason = SyncRuleEngine.validate(probe) {
                showError(reason)
                continue
            }
            channel = candidate
            return true
        }
    }

    private func runSubscriptionsSheet(_ device: inout SyncDevice) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Subscriptions for \(device.Name)"
        alert.informativeText = "The main history is always downloaded. Choose the extra channels this device downloads."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let allCheckbox = NSButton(checkboxWithTitle: "All channels", target: nil, action: nil)
        allCheckbox.setAccessibilityLabel("All channels")
        allCheckbox.setAccessibilityHelp("When checked, this device downloads every channel, including channels added later.")
        allCheckbox.state = device.Channels.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "*" }) ? .on : .off

        let subscribed = Set(device.Channels.map { SyncRuleEngine.normalized($0) })
        var checkboxes: [(key: String, button: NSButton)] = []
        let stack = NSStackView(views: [allCheckbox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        for channel in document.Channels {
            let key = SyncRuleEngine.channelKey(channel.Name)
            guard !key.isEmpty else { continue }
            let checkbox = NSButton(checkboxWithTitle: channel.Name, target: nil, action: nil)
            checkbox.state = subscribed.contains(key) ? .on : .off
            checkbox.setAccessibilityLabel(channel.Name)
            checkbox.setAccessibilityHelp("When checked, \(device.Name) downloads the \(channel.Name) channel.")
            checkboxes.append((key, checkbox))
            stack.addArrangedSubview(checkbox)
        }
        // NSAlert sizes its accessory view from the view's frame, so the stack
        // lives inside a plain container that keeps a frame of its own.
        let container = NSView(frame: NSRect(
            x: 0,
            y: 0,
            width: 420,
            height: max(70, CGFloat(checkboxes.count + 1) * 26 + 12)
        ))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor)
        ])
        alert.accessoryView = container
        alert.window.initialFirstResponder = allCheckbox

        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        if allCheckbox.state == .on {
            device.Channels = ["*"]
            return true
        }
        device.Channels = checkboxes.filter { $0.button.state == .on }.map(\.key)
        return true
    }

    private func splitList(_ value: String) -> [String]? {
        let items = value
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return items.isEmpty ? nil : items
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Clipman Sync Rules"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
