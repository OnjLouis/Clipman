import AppKit
import Carbon
import ClipmanCore

@MainActor
protocol HistoryWindowControllerDelegate: AnyObject {
    func historyWindow(_ controller: HistoryWindowController, didChoose entry: ClipEntry)
    func historyWindow(_ controller: HistoryWindowController, didTogglePin entry: ClipEntry)
    func historyWindow(_ controller: HistoryWindowController, didDelete entry: ClipEntry)
    func historyWindow(_ controller: HistoryWindowController, didEdit entry: ClipEntry, name: String, text: String)
    func historyWindow(_ controller: HistoryWindowController, didCopy entries: [ClipEntry])
    func historyWindow(_ controller: HistoryWindowController, didCut entries: [ClipEntry])
    func historyWindowDidRequestPaste(_ controller: HistoryWindowController, after entry: ClipEntry?)
    func historyWindow(_ controller: HistoryWindowController, didSetGroup group: String, for entries: [ClipEntry])
    func historyWindow(_ controller: HistoryWindowController, didChooseFileEvent event: FileClipboardEvent)
    func historyWindow(_ controller: HistoryWindowController, didTogglePinFileEvent event: FileClipboardEvent)
    func historyWindow(_ controller: HistoryWindowController, didDeleteFileEvent event: FileClipboardEvent)
    func historyWindow(_ controller: HistoryWindowController, didCopyFilePaths events: [FileClipboardEvent])
    func historyWindowDidRequestClearNormalFileHistory(_ controller: HistoryWindowController)
    func historyWindowDidRequestRemoveUnavailableFileHistory(_ controller: HistoryWindowController)
    func historyWindow(_ controller: HistoryWindowController, didChangeModeToFileHistory isFileHistory: Bool)
    func historyWindow(_ controller: HistoryWindowController, didChangeSortMode sortMode: String, fileHistory: Bool)
    func historyWindowDidToggleSortDirection(_ controller: HistoryWindowController, fileHistory: Bool)
    func historyWindow(_ controller: HistoryWindowController, didChangeGroupFilter groupFilter: String)
    func historyWindowDidRequestPreferences(_ controller: HistoryWindowController)
    func historyWindowDidHide(_ controller: HistoryWindowController)
}

final class HistoryWindow: NSWindow {
    var onEnter: (() -> Void)?
    var onShiftEnter: (() -> Void)?
    var onEscape: (() -> Void)?
    var onFind: (() -> Void)?
    var onBackspace: (() -> Void)?
    var onCommandBackspace: (() -> Void)?
    var onEdit: (() -> Void)?
    var onCopy: (() -> Void)?
    var onCut: (() -> Void)?
    var onPaste: (() -> Void)?
    var onGroup: (() -> Void)?
    var onGroupFilter: (() -> Void)?
    var onGroupFilterPosition: ((Int) -> Void)?
    var onSwitchMode: ((Int) -> Void)?
    var onPinnedShortcut: ((Int) -> Void)?
    var onActionsMenu: (() -> Void)?
    var onHide: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if handleClipmanShortcut(event) { return }
        if handleWindowCommand(event) { return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleClipmanShortcut(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    private func handleClipmanShortcut(_ event: NSEvent) -> Bool {
        if let digitIndex = Self.digitIndex(for: event.keyCode) {
            if event.modifierFlags.contains(.command) {
                guard !event.modifierFlags.contains(.shift) else { return false }
                onPinnedShortcut?(digitIndex)
                return true
            }
            if event.modifierFlags.contains(.control), digitIndex == 0 || digitIndex == 1 {
                onSwitchMode?(digitIndex)
                return true
            }
            if event.modifierFlags.contains(.option) {
                onGroupFilterPosition?(digitIndex)
                return true
            }
        }
        if event.keyCode == UInt16(kVK_ANSI_M), event.modifierFlags.contains(.option) {
            onActionsMenu?()
            return true
        }
        if event.keyCode == UInt16(kVK_ANSI_G), event.modifierFlags.contains(.command) {
            onGroup?()
            return true
        }
        if event.keyCode == UInt16(kVK_ANSI_G), event.modifierFlags.contains(.option) {
            onGroupFilter?()
            return true
        }
        return false
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func performClose(_ sender: Any?) {
        hide()
    }

    private func handleWindowCommand(_ event: NSEvent) -> Bool {
        if event.keyCode == UInt16(kVK_Return) {
            if event.modifierFlags.contains(.shift) {
                onShiftEnter?()
                return true
            }
            onEnter?()
            return true
        }
        if event.keyCode == UInt16(kVK_Escape) {
            onEscape?()
            return true
        }
        if event.keyCode == UInt16(kVK_ANSI_F), event.modifierFlags.contains(.command) {
            onFind?()
            return true
        }
        if event.keyCode == UInt16(kVK_Delete) {
            if event.modifierFlags.contains(.command) {
                onCommandBackspace?()
            } else {
                onBackspace?()
            }
            return true
        }
        if event.keyCode == UInt16(kVK_ForwardDelete) {
            onCommandBackspace?()
            return true
        }
        if event.keyCode == UInt16(kVK_F2) {
            onEdit?()
            return true
        }
        if event.keyCode == UInt16(kVK_ANSI_C), event.modifierFlags.contains(.command) {
            onCopy?()
            return true
        }
        if event.keyCode == UInt16(kVK_ANSI_X), event.modifierFlags.contains(.command) {
            onCut?()
            return true
        }
        if event.keyCode == UInt16(kVK_ANSI_V), event.modifierFlags.contains(.command) {
            onPaste?()
            return true
        }
        return false
    }

    private static func digitIndex(for keyCode: UInt16) -> Int? {
        switch Int(keyCode) {
        case kVK_ANSI_1: return 0
        case kVK_ANSI_2: return 1
        case kVK_ANSI_3: return 2
        case kVK_ANSI_4: return 3
        case kVK_ANSI_5: return 4
        case kVK_ANSI_6: return 5
        case kVK_ANSI_7: return 6
        case kVK_ANSI_8: return 7
        case kVK_ANSI_9: return 8
        case kVK_ANSI_0: return 9
        default: return nil
        }
    }

    func hide() {
        orderOut(nil)
        onHide?()
    }

    override func close() {
        super.close()
        onHide?()
    }
}

@MainActor
final class HistoryWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private enum Mode: Int {
        case text = 0
        case files = 1
    }

    private enum Row {
        case separator(String)
        case entry(ClipEntry)
        case fileEvent(FileClipboardEvent)
    }

    weak var historyDelegate: HistoryWindowControllerDelegate?
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let searchField = NSSearchField()
    private let modeControl = NSSegmentedControl(labels: ["Text History", "File History"], trackingMode: .selectOne, target: nil, action: nil)
    private let actionsButton = NSButton(title: "Clipman", target: nil, action: nil)
    private let toolbarStack = NSStackView()
    private let groupButton = NSButton(title: "Set Group...", target: nil, action: nil)
    private let setToFilterButton = NSButton(title: "Set to Filter", target: nil, action: nil)
    private let groupFilterButton = NSButton(title: "Filter: All", target: nil, action: nil)
    private let selectedGroupLabel = NSTextField(labelWithString: "Selected group: None")
    private let sortButton = NSButton(title: "Sort: Last used", target: nil, action: nil)
    private let directionButton = NSButton(title: "Newest first", target: nil, action: nil)
    private let preferencesButton = NSButton(title: "Preferences...", target: nil, action: nil)
    private var mode: Mode = .text
    private var textSortMode = "LastUsed"
    private var textSortDescending = true
    private var fileSortMode = "Manual"
    private var fileSortDescending = false
    private var groupFilter = "All"
    private var allEntries: [ClipEntry] = []
    private var filteredEntries: [ClipEntry] = []
    private var allFileEvents: [FileClipboardEvent] = []
    private var filteredFileEvents: [FileClipboardEvent] = []
    private var rows: [Row] = []
    private var preferredRowAfterReload: Int?
    private var keyMonitor: Any?
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    init() {
        let window = HistoryWindow(
            contentRect: NSRect(x: 100, y: 100, width: 760, height: 520),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Clipman History"
        super.init(window: window)
        window.onEnter = { [weak self] in self?.chooseSelectedEntry() }
        window.onShiftEnter = { [weak self] in self?.toggleSelectedPin() }
        window.onEscape = { [weak self] in (self?.window as? HistoryWindow)?.hide() }
        window.onFind = { [weak self] in self?.focusSearch() }
        window.onBackspace = { [weak self] in self?.jumpToFirstNormalEntry() }
        window.onCommandBackspace = { [weak self] in self?.deleteSelectedEntry() }
        window.onEdit = { [weak self] in self?.editSelectedEntry() }
        window.onCopy = { [weak self] in self?.copySelectedEntries() }
        window.onCut = { [weak self] in self?.cutSelectedEntries() }
        window.onPaste = { [weak self] in self?.pasteAfterSelectedEntry() }
        window.onGroup = { [weak self] in self?.groupSelectedEntries() }
        window.onGroupFilter = { [weak self] in self?.showGroupFilterMenu() }
        window.onGroupFilterPosition = { [weak self] index in self?.applyGroupFilter(at: index) }
        window.onSwitchMode = { [weak self] index in self?.setMode(index == 1 ? .files : .text, notify: true) }
        window.onPinnedShortcut = { [weak self] index in self?.activatePinnedShortcut(index: index) }
        window.onActionsMenu = { [weak self] in self?.showActionsMenu() }
        window.onHide = { [weak self] in
            guard let self else { return }
            self.historyDelegate?.historyWindowDidHide(self)
        }
        buildUI()
        installKeyMonitor()
    }

    func hide() {
        (window as? HistoryWindow)?.hide()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(entries: [ClipEntry]) {
        let selectedID = selectedID()
        allEntries = entries
        applyFilter(preferredSelectedID: selectedID)
    }

    func update(fileEvents: [FileClipboardEvent]) {
        let selectedID = selectedID()
        allFileEvents = fileEvents
        applyFilter(preferredSelectedID: selectedID)
    }

    func showFileHistory() {
        setMode(.files, notify: true)
    }

    func configureSort(textSortMode: String, textDescending: Bool, fileSortMode: String, fileDescending: Bool, selectedTab: Int, groupFilter: String) {
        self.textSortMode = textSortMode
        self.textSortDescending = textDescending
        self.fileSortMode = fileSortMode
        self.fileSortDescending = fileDescending
        self.groupFilter = groupFilter.isEmpty ? "All" : groupFilter
        mode = selectedTab == 1 ? .files : .text
        modeControl.selectedSegment = mode.rawValue
        updateToolbarState()
        applyFilter(preferredSelectedID: selectedID())
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
        tableView.window?.makeFirstResponder(tableView)
        if tableView.selectedRow < 0 && !filteredEntries.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        searchField.placeholderString = "Search"
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.setAccessibilityLabel("Search history, Command+F")
        stack.addArrangedSubview(searchField)

        modeControl.selectedSegment = mode.rawValue
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.setAccessibilityLabel("History type. Text History, Control+1. File History, Control+2.")
        stack.addArrangedSubview(modeControl)

        configureToolbar()
        stack.addArrangedSubview(toolbarStack)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
        column.title = "Clipboard history"
        column.width = 720
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.delegate = self
        tableView.dataSource = self
        tableView.allowsMultipleSelection = true
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.target = self
        tableView.doubleAction = #selector(doubleClicked)
        updateTableAccessibility()

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        stack.addArrangedSubview(scrollView)
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
        updateToolbarState()
    }

    private func configureToolbar() {
        toolbarStack.orientation = .horizontal
        toolbarStack.alignment = .centerY
        toolbarStack.spacing = 8
        toolbarStack.setAccessibilityLabel("Clipman toolbar")

        configureToolbarButton(actionsButton, title: "Clipman", action: #selector(actionsClicked), tabbable: true, accessibilityLabel: "Clipman menu, Option+M")
        configureToolbarButton(groupButton, title: "Set Group...", action: #selector(groupToolbarClicked), accessibilityLabel: "Set selected entries group, Command+G")
        configureToolbarButton(setToFilterButton, title: "Set to Filter", action: #selector(setToFilterToolbarClicked), accessibilityLabel: "Set selected entries to current group filter")
        configureToolbarButton(groupFilterButton, title: "Filter: All", action: #selector(groupFilterToolbarClicked), accessibilityLabel: "Filter by group, Option+G")
        configureToolbarButton(sortButton, title: "Sort: Last used", action: #selector(sortToolbarClicked), accessibilityLabel: "Sort history")
        configureToolbarButton(directionButton, title: "Newest first", action: #selector(directionToolbarClicked), accessibilityLabel: "Toggle sort direction")
        configureToolbarButton(preferencesButton, title: "Preferences...", action: #selector(preferencesToolbarClicked), accessibilityLabel: "Preferences, Command+,")

        toolbarStack.addArrangedSubview(actionsButton)
        toolbarStack.addArrangedSubview(groupButton)
        toolbarStack.addArrangedSubview(setToFilterButton)
        toolbarStack.addArrangedSubview(groupFilterButton)
        toolbarStack.addArrangedSubview(selectedGroupLabel)
        toolbarStack.addArrangedSubview(sortButton)
        toolbarStack.addArrangedSubview(directionButton)
        toolbarStack.addArrangedSubview(preferencesButton)
        selectedGroupLabel.setAccessibilityLabel("Selected entry group")
    }

    private func configureToolbarButton(_ button: NSButton, title: String, action: Selector, tabbable: Bool = false, accessibilityLabel: String) {
        button.title = title
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
        button.refusesFirstResponder = !tabbable
        button.setAccessibilityLabel(accessibilityLabel)
    }

    private func updateToolbarState() {
        let textMode = mode == .text
        groupButton.isHidden = !textMode
        setToFilterButton.isHidden = !textMode || isReservedGroupFilter(groupFilter)
        groupFilterButton.isHidden = !textMode
        selectedGroupLabel.isHidden = !textMode
        setToFilterButton.title = "Set to \(groupFilter)"
        setToFilterButton.setAccessibilityLabel("Set selected entries to \(groupFilter)")
        groupFilterButton.title = "Filter: \(groupFilter.isEmpty ? "All" : groupFilter)"
        groupFilterButton.setAccessibilityLabel("Filter by group, Option+G, current filter \(groupFilter.isEmpty ? "All" : groupFilter)")
        updateSelectedGroupStatus()

        let selectedSort = sortOptions().first {
            $0.value.caseInsensitiveCompare(currentSortMode()) == .orderedSame
        }?.title ?? currentSortMode()
        sortButton.title = "Sort: \(selectedSort)"
        sortButton.setAccessibilityLabel("Sort \(mode == .files ? "file history" : "text history"), current sort \(selectedSort)")

        let direction = sortDirectionTitle(descending: currentSortDescending())
        directionButton.title = direction
        directionButton.setAccessibilityLabel("Sort direction, \(direction)")
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  let window = self.window,
                  window.isVisible,
                  window.isKeyWindow
            else { return event }
            guard let historyWindow = window as? HistoryWindow else { return event }
            if historyWindow.performKeyEquivalent(with: event) {
                return nil
            }
            return event
        }
    }

    @objc private func searchChanged() {
        applyFilter(preferredSelectedID: nil)
    }

    @objc private func modeChanged() {
        setMode(Mode(rawValue: modeControl.selectedSegment) ?? .text, notify: true)
    }

    @objc private func actionsClicked() {
        showActionsMenu()
    }

    @objc private func groupToolbarClicked() {
        groupSelectedEntries()
    }

    @objc private func setToFilterToolbarClicked() {
        groupSelectedEntriesToCurrentFilter()
    }

    @objc private func groupFilterToolbarClicked() {
        showGroupFilterMenu()
    }

    @objc private func sortToolbarClicked() {
        showSortMenu(from: sortButton)
    }

    @objc private func directionToolbarClicked() {
        menuToggleDirection()
    }

    @objc private func preferencesToolbarClicked() {
        historyDelegate?.historyWindowDidRequestPreferences(self)
    }

    @objc private func doubleClicked() {
        chooseSelectedEntry()
    }

    private func setMode(_ newMode: Mode, notify: Bool) {
        mode = newMode
        modeControl.selectedSegment = newMode.rawValue
        updateTableAccessibility()
        updateToolbarState()
        applyFilter(preferredSelectedID: nil)
        if notify {
            historyDelegate?.historyWindow(self, didChangeModeToFileHistory: mode == .files)
        }
        tableView.window?.makeFirstResponder(tableView)
    }

    private func applyFilter(preferredSelectedID: String?) {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch mode {
        case .text:
            let grouped = filterEntriesByGroup(allEntries)
            if query.isEmpty {
                filteredEntries = grouped
            } else {
                filteredEntries = grouped.filter {
                    $0.Text.lowercased().contains(query) || $0.Name.lowercased().contains(query) || $0.Group.lowercased().contains(query)
                }
            }
        case .files:
            if query.isEmpty {
                filteredFileEvents = allFileEvents
            } else {
                filteredFileEvents = allFileEvents.filter { event in
                    event.Files.contains { $0.lowercased().contains(query) } ||
                    event.Source.lowercased().contains(query) ||
                    event.Operation.lowercased().contains(query)
                }
            }
        }
        rebuildRows()
        tableView.reloadData()
        updateTableAccessibility()
        if let preferredSelectedID,
           let index = rows.firstIndex(where: { row in
               switch row {
               case .entry(let entry): return entry.Id == preferredSelectedID
               case .fileEvent(let event): return event.Id == preferredSelectedID
               case .separator: return false
               }
           }) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else if let preferredRowAfterReload {
            self.preferredRowAfterReload = nil
            let clamped = max(0, min(preferredRowAfterReload, rows.count - 1))
            if let selectable = firstSelectableRow(startingAt: clamped) {
                tableView.selectRowIndexes(IndexSet(integer: selectable), byExtendingSelection: false)
                tableView.scrollRowToVisible(selectable)
            }
        } else if rows.contains(where: { if case .separator = $0 { return false }; return true }) {
            let selectedRow = firstSelectableRow(startingAt: min(max(tableView.selectedRow, 0), rows.count - 1)) ?? firstSelectableRow(startingAt: 0) ?? 0
            tableView.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
        }
    }

    private func filterEntriesByGroup(_ entries: [ClipEntry]) -> [ClipEntry] {
        let filter = groupFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filter.isEmpty && filter.caseInsensitiveCompare("All") != .orderedSame else { return entries }
        if filter.caseInsensitiveCompare("Pinned") == .orderedSame {
            return entries.filter(\.Pinned)
        }
        if filter.caseInsensitiveCompare("Named") == .orderedSame {
            return entries.filter { !$0.Name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        if filter.caseInsensitiveCompare("Ungrouped") == .orderedSame {
            return entries.filter { $0.Group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        return entries.filter { $0.Group.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(filter) == .orderedSame }
    }

    private func rebuildRows() {
        rows.removeAll()
        switch mode {
        case .text:
            let pinned = filteredEntries.filter(\.Pinned)
            let normal = filteredEntries.filter { !$0.Pinned }
            rows.append(contentsOf: pinned.map(Row.entry))
            if !pinned.isEmpty && !normal.isEmpty {
                rows.append(.separator("Normal entries"))
            }
            rows.append(contentsOf: normal.map(Row.entry))
        case .files:
            let pinned = filteredFileEvents.filter(\.Pinned)
            let normal = filteredFileEvents.filter { !$0.Pinned }
            rows.append(contentsOf: pinned.map(Row.fileEvent))
            if !pinned.isEmpty && !normal.isEmpty {
                rows.append(.separator("Normal file events"))
            }
            rows.append(contentsOf: normal.map(Row.fileEvent))
        }
    }

    private func selectedID() -> String? {
        switch rows.indices.contains(tableView.selectedRow) ? rows[tableView.selectedRow] : nil {
        case .entry(let entry): return entry.Id
        case .fileEvent(let event): return event.Id
        case .separator, nil: return nil
        }
    }

    private func sortDirectionTitle(descending: Bool) -> String {
        if mode == .files {
            switch fileSortMode.uppercased() {
            case "TIME": return descending ? "Newest first" : "Oldest first"
            case "FILES": return descending ? "Most files first" : "Fewest files first"
            case "NAME", "OPERATION", "SOURCE": return descending ? "Z first" : "A first"
            default: return descending ? "Bottom manual item first" : "Top manual item first"
            }
        }
        switch textSortMode.uppercased() {
        case "LASTUSED", "ADDED": return descending ? "Newest first" : "Oldest first"
        case "TEXT", "GROUP", "MACHINE": return descending ? "Z first" : "A first"
        default: return descending ? "Bottom manual item first" : "Top manual item first"
        }
    }

    private func updateTableAccessibility() {
        tableView.setAccessibilityLabel(mode == .files ? "File history" : "Text history")
        tableView.tableColumns.first?.title = mode == .files ? "File history" : "Text history"
    }

    private func showActionsMenu() {
        let menu = NSMenu(title: "Clipman")
        addMenuItem("Choose Selected", action: #selector(menuChooseSelected), to: menu, shortcut: "Enter")
        addMenuItem(mode == .files ? "Copy Selected Paths" : "Copy Selected", action: #selector(menuCopySelected), to: menu, shortcut: "Command+C")
        if mode == .text {
            addMenuItem("Cut Selected", action: #selector(menuCutSelected), to: menu, shortcut: "Command+X")
            addMenuItem("Paste After Selected", action: #selector(menuPasteAfterSelected), to: menu, shortcut: "Command+V")
            addMenuItem("Edit Selected", action: #selector(menuEditSelected), to: menu, shortcut: "F2")
        }
        addMenuItem("Pin or Unpin Selected", action: #selector(menuTogglePin), to: menu, shortcut: "Shift+Enter")
        addMenuItem("Delete Selected", action: #selector(menuDeleteSelected), to: menu, shortcut: "Command+Backspace")
        menu.addItem(.separator())
        if mode == .text {
            addMenuItem("Group Selected...", action: #selector(menuGroupSelected), to: menu, shortcut: "Command+G")
            if !isReservedGroupFilter(groupFilter) {
                addMenuItem("Set Selected to \(groupFilter)", action: #selector(menuGroupSelectedToCurrentFilter), to: menu)
            }
            addGroupFilterItems(to: menu)
            menu.addItem(.separator())
        }
        addMenuItem("Text History", action: #selector(menuTextHistory), to: menu, shortcut: "Control+1").state = mode == .text ? .on : .off
        addMenuItem("File History", action: #selector(menuFileHistory), to: menu, shortcut: "Control+2").state = mode == .files ? .on : .off
        menu.addItem(.separator())

        let sortMenu = NSMenu(title: mode == .files ? "Sort File History By" : "Sort Text History By")
        for option in sortOptions() {
            let item = addMenuItem(option.title, action: #selector(menuSortChanged(_:)), to: sortMenu, shortcut: nil)
            item.representedObject = option.value
            item.state = option.value.caseInsensitiveCompare(currentSortMode()) == .orderedSame ? .on : .off
        }
        let sortRoot = NSMenuItem(title: sortMenu.title, action: nil, keyEquivalent: "")
        sortRoot.submenu = sortMenu
        menu.addItem(sortRoot)
        addMenuItem(sortDirectionTitle(descending: currentSortDescending()), action: #selector(menuToggleDirection), to: menu)

        menu.addItem(.separator())
        addMenuItem("Jump To Normal Entries", action: #selector(menuJumpToNormal), to: menu, shortcut: "Backspace")
        addMenuItem("Find", action: #selector(menuFind), to: menu, shortcut: "Command+F")
        addMenuItem("Preferences...", action: #selector(menuPreferences), to: menu, shortcut: "Command+,")
        menu.addItem(.separator())
        addPinnedShortcutItems(to: menu)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: actionsButton.bounds.height + 2), in: actionsButton)
    }

    private func showSortMenu(from anchor: NSView) {
        let menu = NSMenu(title: mode == .files ? "Sort File History By" : "Sort Text History By")
        for option in sortOptions() {
            let item = addMenuItem(option.title, action: #selector(menuSortChanged(_:)), to: menu)
            item.representedObject = option.value
            item.state = option.value.caseInsensitiveCompare(currentSortMode()) == .orderedSame ? .on : .off
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 2), in: anchor)
    }

    private func showGroupFilterMenu() {
        guard mode == .text else {
            setMode(.text, notify: true)
            return
        }
        let menu = NSMenu(title: "Group Filter")
        for group in reservedGroupFilterItems() {
            let item = addMenuItem(group, action: #selector(menuGroupFilterChanged(_:)), to: menu)
            item.representedObject = group
            item.state = group.caseInsensitiveCompare(groupFilter) == .orderedSame ? .on : .off
        }
        let groups = numberedGroupFilterItems()
        if !groups.isEmpty {
            menu.addItem(.separator())
        }
        for (index, group) in groups.enumerated() {
            let shortcut = groupShortcutLabel(index: index)
            let item = addMenuItem(group, action: #selector(menuGroupFilterChanged(_:)), to: menu, shortcut: shortcut)
            item.representedObject = group
            item.state = group.caseInsensitiveCompare(groupFilter) == .orderedSame ? .on : .off
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: actionsButton.bounds.height + 2), in: actionsButton)
    }

    private func addGroupFilterItems(to menu: NSMenu) {
        let groupMenu = NSMenu(title: "Group Filter")
        for group in reservedGroupFilterItems() {
            let item = addMenuItem(group, action: #selector(menuGroupFilterChanged(_:)), to: groupMenu)
            item.representedObject = group
            item.state = group.caseInsensitiveCompare(groupFilter) == .orderedSame ? .on : .off
        }
        let groups = numberedGroupFilterItems()
        if !groups.isEmpty {
            groupMenu.addItem(.separator())
        }
        for (index, group) in groups.enumerated() {
            let shortcut = groupShortcutLabel(index: index)
            let item = addMenuItem(group, action: #selector(menuGroupFilterChanged(_:)), to: groupMenu, shortcut: shortcut)
            item.representedObject = group
            item.state = group.caseInsensitiveCompare(groupFilter) == .orderedSame ? .on : .off
        }
        let root = NSMenuItem(title: "Group Filter\tOption+G", action: nil, keyEquivalent: "")
        root.submenu = groupMenu
        menu.addItem(root)
    }

    @discardableResult
    private func addMenuItem(_ title: String, action: Selector, to menu: NSMenu, shortcut: String? = nil) -> NSMenuItem {
        let displayTitle = shortcut.map { "\(title)\t\($0)" } ?? title
        let item = NSMenuItem(title: displayTitle, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    private func sortOptions() -> [(value: String, title: String)] {
        mode == .files
            ? [("Time", "Time captured"), ("Files", "File count"), ("Name", "Name"), ("Operation", "Operation"), ("Source", "Source application"), ("Manual", "Manual order")]
            : [("LastUsed", "Last used"), ("Added", "Added"), ("Text", "Text"), ("Group", "Group"), ("Machine", "Machine"), ("Manual", "Manual order")]
    }

    private func currentSortMode() -> String {
        mode == .files ? fileSortMode : textSortMode
    }

    private func currentSortDescending() -> Bool {
        mode == .files ? fileSortDescending : textSortDescending
    }

    private func addPinnedShortcutItems(to menu: NSMenu) {
        let pinned = pinnedRows()
        guard !pinned.isEmpty else { return }
        let pinnedMenu = NSMenu(title: "Pinned Shortcuts")
        for (index, row) in pinned.prefix(10).enumerated() {
            let number = index == 9 ? "0" : "\(index + 1)"
            let title = "\(number). \(rowTitle(row))"
            let choose = addMenuItem("Choose \(title)", action: #selector(menuPinnedChoose(_:)), to: pinnedMenu, shortcut: "Command+\(number)")
            choose.representedObject = index
        }
        let pinnedRoot = NSMenuItem(title: "Pinned Shortcuts", action: nil, keyEquivalent: "")
        pinnedRoot.submenu = pinnedMenu
        menu.addItem(pinnedRoot)
    }

    private func rowTitle(_ row: Row) -> String {
        switch row {
        case .entry(let entry):
            let text = entry.Name.isEmpty ? entry.Text : entry.Name
            return String(text.prefix(60))
        case .fileEvent(let event):
            return String(fileEventLabel(event).prefix(60))
        case .separator(let title):
            return title
        }
    }

    private func pinnedRows() -> [Row] {
        switch mode {
        case .text: return filteredEntries.filter(\.Pinned).map(Row.entry)
        case .files: return filteredFileEvents.filter(\.Pinned).map(Row.fileEvent)
        }
    }

    private func activatePinnedShortcut(index: Int) {
        let pinned = pinnedRows()
        guard index >= 0 && index < pinned.count else {
            NSSound.beep()
            return
        }
        switch pinned[index] {
        case .entry(let entry):
            historyDelegate?.historyWindow(self, didChoose: entry)
        case .fileEvent(let event):
            historyDelegate?.historyWindow(self, didChooseFileEvent: event)
        case .separator:
            break
        }
    }

    @objc private func menuChooseSelected() { chooseSelectedEntry() }
    @objc private func menuCopySelected() { copySelectedEntries() }
    @objc private func menuCutSelected() { cutSelectedEntries() }
    @objc private func menuPasteAfterSelected() { pasteAfterSelectedEntry() }
    @objc private func menuEditSelected() { editSelectedEntry() }
    @objc private func menuGroupSelected() { groupSelectedEntries() }
    @objc private func menuGroupSelectedToCurrentFilter() { groupSelectedEntriesToCurrentFilter() }
    @objc private func menuTogglePin() { toggleSelectedPin() }
    @objc private func menuDeleteSelected() { deleteSelectedEntry() }
    @objc private func menuTextHistory() { setMode(.text, notify: true) }
    @objc private func menuFileHistory() { setMode(.files, notify: true) }
    @objc private func menuJumpToNormal() { jumpToFirstNormalEntry() }
    @objc private func menuFind() { focusSearch() }
    @objc private func menuPreferences() { historyDelegate?.historyWindowDidRequestPreferences(self) }
    @objc private func menuToggleDirection() {
        if mode == .files {
            fileSortDescending.toggle()
        } else {
            textSortDescending.toggle()
        }
        updateToolbarState()
        historyDelegate?.historyWindowDidToggleSortDirection(self, fileHistory: mode == .files)
    }

    @objc private func menuSortChanged(_ sender: NSMenuItem) {
        guard let sortMode = sender.representedObject as? String else { return }
        if mode == .files {
            fileSortMode = sortMode
        } else {
            textSortMode = sortMode
        }
        updateToolbarState()
        historyDelegate?.historyWindow(self, didChangeSortMode: sortMode, fileHistory: mode == .files)
    }

    @objc private func menuPinnedChoose(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        activatePinnedShortcut(index: index)
    }

    @objc private func menuGroupFilterChanged(_ sender: NSMenuItem) {
        guard let group = sender.representedObject as? String else { return }
        setGroupFilter(group)
    }

    private func applyGroupFilter(at index: Int) {
        guard mode == .text else {
            setMode(.text, notify: true)
            return
        }
        let groups = numberedGroupFilterItems()
        guard index >= 0 && index < groups.count else {
            NSSound.beep()
            return
        }
        setGroupFilter(groups[index])
    }

    private func setGroupFilter(_ group: String) {
        groupFilter = group
        updateToolbarState()
        historyDelegate?.historyWindow(self, didChangeGroupFilter: group)
        applyFilter(preferredSelectedID: nil)
    }

    private func selectedEntry() -> ClipEntry? {
        let row = tableView.selectedRow
        guard row >= 0 && row < rows.count else { return nil }
        if case .entry(let entry) = rows[row] {
            return entry
        }
        return nil
    }

    private func selectedEntries() -> [ClipEntry] {
        tableView.selectedRowIndexes.compactMap { row in
            guard row >= 0 && row < rows.count else { return nil }
            if case .entry(let entry) = rows[row] { return entry }
            return nil
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateSelectedGroupStatus()
    }

    private func selectedFileEvent() -> FileClipboardEvent? {
        let row = tableView.selectedRow
        guard row >= 0 && row < rows.count else { return nil }
        if case .fileEvent(let event) = rows[row] {
            return event
        }
        return nil
    }

    private func selectedFileEvents() -> [FileClipboardEvent] {
        tableView.selectedRowIndexes.compactMap { row in
            guard row >= 0 && row < rows.count else { return nil }
            if case .fileEvent(let event) = rows[row] { return event }
            return nil
        }
    }

    private func chooseSelectedEntry() {
        if let entry = selectedEntry() {
            historyDelegate?.historyWindow(self, didChoose: entry)
        } else if let event = selectedFileEvent() {
            historyDelegate?.historyWindow(self, didChooseFileEvent: event)
        }
    }

    private func toggleSelectedPin() {
        if let entry = selectedEntry() {
            historyDelegate?.historyWindow(self, didTogglePin: entry)
        } else if let event = selectedFileEvent() {
            historyDelegate?.historyWindow(self, didTogglePinFileEvent: event)
        }
    }

    private func deleteSelectedEntry() {
        if mode == .files, NSEvent.modifierFlags.contains(.control) {
            historyDelegate?.historyWindowDidRequestClearNormalFileHistory(self)
            return
        }
        if mode == .files, NSEvent.modifierFlags.contains(.option) {
            historyDelegate?.historyWindowDidRequestRemoveUnavailableFileHistory(self)
            return
        }
        switch mode {
        case .text:
            let entries = selectedEntries()
            guard !entries.isEmpty else { return }
            if entries.contains(where: \.Pinned) {
                NSSound.beep()
                return
            }
            preferredRowAfterReload = tableView.selectedRowIndexes.min()
            for entry in entries {
                historyDelegate?.historyWindow(self, didDelete: entry)
            }
        case .files:
            let events = selectedFileEvents()
            guard !events.isEmpty else { return }
            if events.contains(where: \.Pinned) {
                NSSound.beep()
                return
            }
            preferredRowAfterReload = tableView.selectedRowIndexes.min()
            for event in events {
                historyDelegate?.historyWindow(self, didDeleteFileEvent: event)
            }
        }
    }

    private func editSelectedEntry() {
        guard let entry = selectedEntry() else { return }
        let alert = NSAlert()
        alert.messageText = "Edit Clipboard Entry"
        alert.informativeText = "Edit the entry name and stored clipboard text."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let nameField = NSTextField(string: entry.Name)
        nameField.placeholderString = "Name"
        nameField.setAccessibilityLabel("Entry name")
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 180))
        textView.string = entry.Text
        textView.isRichText = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.setAccessibilityLabel("Clipboard text")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 180))
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.documentView = textView
        let stack = NSStackView(views: [nameField, scroll])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 520, height: 220)
        alert.accessoryView = stack

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        historyDelegate?.historyWindow(self, didEdit: entry, name: nameField.stringValue, text: textView.string)
    }

    private func copySelectedEntries() {
        switch mode {
        case .text:
            let entries = selectedEntries()
            guard !entries.isEmpty else { return }
            historyDelegate?.historyWindow(self, didCopy: entries)
        case .files:
            let events = selectedFileEvents()
            guard !events.isEmpty else { return }
            historyDelegate?.historyWindow(self, didCopyFilePaths: events)
        }
    }

    private func cutSelectedEntries() {
        guard mode == .text else {
            copySelectedEntries()
            return
        }
        let entries = selectedEntries()
        guard !entries.isEmpty else { return }
        preferredRowAfterReload = tableView.selectedRowIndexes.min()
        historyDelegate?.historyWindow(self, didCut: entries)
    }

    private func groupSelectedEntries() {
        guard mode == .text else {
            NSSound.beep()
            return
        }
        let entries = selectedEntries()
        guard !entries.isEmpty else { return }
        let groups = existingGroups()
        let activeGroup = isReservedGroupFilter(groupFilter) ? "" : groupFilter
        let selectedGroups = Set(entries.map { $0.Group.trimmingCharacters(in: .whitespacesAndNewlines) })
        let initial = !activeGroup.isEmpty ? activeGroup : (selectedGroups.count == 1 ? entries[0].Group : "")
        let alert = NSAlert()
        alert.messageText = "Group Clipboard Entries"
        alert.informativeText = "Enter a group name, or leave it blank to remove the selected entries from a group."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let groupBox = NSComboBox()
        groupBox.stringValue = initial
        groupBox.placeholderString = "Group"
        groupBox.setAccessibilityLabel("Entry group")
        groupBox.addItem(withObjectValue: "(No group)")
        for group in groups {
            groupBox.addItem(withObjectValue: group)
        }
        let stack = NSStackView(views: [groupBox])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: 28)
        alert.accessoryView = stack
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = groupBox.stringValue == "(No group)" ? "" : groupBox.stringValue
        historyDelegate?.historyWindow(self, didSetGroup: value, for: entries)
    }

    private func groupSelectedEntriesToCurrentFilter() {
        guard mode == .text, !isReservedGroupFilter(groupFilter) else {
            NSSound.beep()
            return
        }
        let entries = selectedEntries()
        guard !entries.isEmpty else {
            NSSound.beep()
            return
        }
        historyDelegate?.historyWindow(self, didSetGroup: groupFilter, for: entries)
        updateSelectedGroupStatus()
    }

    private func pasteAfterSelectedEntry() {
        guard mode == .text else {
            NSSound.beep()
            return
        }
        historyDelegate?.historyWindowDidRequestPaste(self, after: selectedEntry())
    }

    private func jumpToFirstNormalEntry() {
        guard let index = rows.firstIndex(where: {
            if case .entry(let entry) = $0 { return !entry.Pinned }
            if case .fileEvent(let event) = $0 { return !event.Pinned }
            return false
        }) else { return }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
    }

    private func focusSearch() {
        window?.makeFirstResponder(searchField)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("entryCell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = id
        let textField = cell.textField ?? NSTextField(labelWithString: "")
        textField.lineBreakMode = .byTruncatingTail
        textField.maximumNumberOfLines = 2
        textField.translatesAutoresizingMaskIntoConstraints = false
        if textField.superview == nil {
            cell.addSubview(textField)
            cell.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        switch rows[row] {
        case .separator(let title):
            textField.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            textField.textColor = .secondaryLabelColor
            textField.stringValue = title
            cell.setAccessibilityLabel(title)
        case .entry(let entry):
            textField.font = .systemFont(ofSize: NSFont.systemFontSize)
            textField.textColor = .labelColor
            let label = entry.Name.isEmpty ? entry.Text : "\(entry.Name): \(entry.Text)"
            let metadata = metadataText(for: entry)
            textField.stringValue = metadata.isEmpty ? label : "\(entry.Pinned ? "Pinned, " : "")\(label)\n\(metadata)"
            cell.setAccessibilityLabel(textField.stringValue.replacingOccurrences(of: "\n", with: ", "))
        case .fileEvent(let event):
            textField.font = .systemFont(ofSize: NSFont.systemFontSize)
            textField.textColor = .labelColor
            let label = fileEventLabel(event)
            let metadata = fileEventMetadata(event)
            textField.stringValue = metadata.isEmpty ? label : "\(event.Pinned ? "Pinned, " : "")\(label)\n\(metadata)"
            cell.setAccessibilityLabel(textField.stringValue.replacingOccurrences(of: "\n", with: ", "))
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .separator = rows[row] { return 28 }
        return 56
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .separator = rows[row] { return false }
        return true
    }

    private func firstSelectableRow(startingAt start: Int) -> Int? {
        guard !rows.isEmpty else { return nil }
        for index in start..<rows.count {
            if case .separator = rows[index] {} else { return index }
        }
        for index in stride(from: start, through: 0, by: -1) {
            if case .separator = rows[index] {} else { return index }
        }
        return nil
    }

    private func groupFilterItems() -> [String] {
        reservedGroupFilterItems() + numberedGroupFilterItems()
    }

    private func reservedGroupFilterItems() -> [String] {
        ["All", "Pinned", "Named", "Ungrouped"]
    }

    private func numberedGroupFilterItems() -> [String] {
        existingGroups()
    }

    private func groupShortcutLabel(index: Int) -> String? {
        guard index >= 0 && index < 10 else { return nil }
        return "Option+\(index == 9 ? "0" : "\(index + 1)")"
    }

    private func isReservedGroupFilter(_ group: String) -> Bool {
        reservedGroupFilterItems().contains { $0.caseInsensitiveCompare(group) == .orderedSame }
    }

    private func updateSelectedGroupStatus() {
        guard mode == .text else { return }
        let entries = selectedEntries()
        let label: String
        if entries.isEmpty {
            label = "Selected group: None"
        } else {
            let groups = Set(entries.map { $0.Group.trimmingCharacters(in: .whitespacesAndNewlines) })
            if groups.count == 1 {
                let group = groups.first ?? ""
                label = group.isEmpty ? "Selected group: Ungrouped" : "Selected group: \(group)"
            } else {
                label = "Selected group: Mixed"
            }
        }
        selectedGroupLabel.stringValue = label
        selectedGroupLabel.setAccessibilityValue(label)
    }

    private func existingGroups() -> [String] {
        let reserved = Set(["all", "pinned", "named", "ungrouped"])
        return allEntries
            .map { $0.Group.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !reserved.contains($0.lowercased()) }
            .reduce(into: [String]()) { result, group in
                if !result.contains(where: { $0.caseInsensitiveCompare(group) == .orderedSame }) {
                    result.append(group)
                }
            }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func metadataText(for entry: ClipEntry) -> String {
        var parts: [String] = []
        if !entry.Group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("Group: \(entry.Group)")
        }
        if !entry.SourceMachine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("Machine: \(entry.SourceMachine)")
        }
        if entry.LastUsedUnixMs > 0 {
            let date = Date(timeIntervalSince1970: TimeInterval(entry.LastUsedUnixMs) / 1000.0)
            parts.append("Last used: \(dateFormatter.string(from: date))")
        }
        return parts.joined(separator: " - ")
    }

    private func fileEventLabel(_ event: FileClipboardEvent) -> String {
        let primary = event.Files.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "File event"
        let count = event.Files.count
        let suffix = count == 1 ? "1 item" : "\(count) items"
        return "\(primary), \(event.Operation.isEmpty ? "Copy" : event.Operation), \(suffix)"
    }

    private func fileEventMetadata(_ event: FileClipboardEvent) -> String {
        var parts: [String] = []
        if !event.Source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("Source: \(event.Source)")
        }
        if !event.SourceMachine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("Machine: \(event.SourceMachine)")
        }
        if event.CapturedUnixMs > 0 {
            let date = Date(timeIntervalSince1970: TimeInterval(event.CapturedUnixMs) / 1000.0)
            parts.append("Captured: \(dateFormatter.string(from: date))")
        }
        return parts.joined(separator: " - ")
    }
}
