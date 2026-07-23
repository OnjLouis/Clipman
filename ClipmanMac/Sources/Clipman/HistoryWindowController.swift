import AppKit
import Carbon
import ClipmanCore

private final class MetadataTableDataSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let rows: [(String, String)]

    init(rows: [(String, String)]) {
        self.rows = rows
        super.init()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let value = tableColumn?.identifier.rawValue == "value" ? rows[row].1 : rows[row].0
        let identifier = NSUserInterfaceItemIdentifier(tableColumn?.identifier.rawValue ?? "detail")
        let field = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField) ?? NSTextField(labelWithString: "")
        field.identifier = identifier
        field.stringValue = value
        field.lineBreakMode = .byTruncatingTail
        field.setAccessibilityLabel(value)
        return field
    }
}

@MainActor
private final class QuickPasteModeRadioGroup: NSObject {
    private let pasteRestoreButton: NSButton
    private let pasteKeepButton: NSButton
    private let copyOnlyButton: NSButton
    private(set) var selectedMode: QuickPasteMode

    init(pasteRestoreButton: NSButton, pasteKeepButton: NSButton, copyOnlyButton: NSButton, selectedMode: QuickPasteMode) {
        self.pasteRestoreButton = pasteRestoreButton
        self.pasteKeepButton = pasteKeepButton
        self.copyOnlyButton = copyOnlyButton
        self.selectedMode = selectedMode
        super.init()
        for button in [pasteRestoreButton, pasteKeepButton, copyOnlyButton] {
            button.target = self
            button.action = #selector(modeChanged(_:))
        }
        applySelection()
    }

    @objc private func modeChanged(_ sender: NSButton) {
        if sender === pasteKeepButton {
            selectedMode = .pasteKeep
        } else if sender === copyOnlyButton {
            selectedMode = .copyOnly
        } else {
            selectedMode = .pasteRestore
        }
        applySelection()
    }

    private func applySelection() {
        pasteRestoreButton.state = selectedMode == .pasteRestore ? .on : .off
        pasteKeepButton.state = selectedMode == .pasteKeep ? .on : .off
        copyOnlyButton.state = selectedMode == .copyOnly ? .on : .off
    }
}

private class BoundaryAwareTextView: NSTextView {
    override func keyDown(with event: NSEvent) {
        if handleBoundaryNavigation(event) {
            return
        }
        super.keyDown(with: event)
    }

    private func handleBoundaryNavigation(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard modifiers.contains(.option),
              !modifiers.contains(.command),
              !modifiers.contains(.control),
              event.keyCode == UInt16(kVK_LeftArrow) || event.keyCode == UInt16(kVK_RightArrow)
        else {
            return false
        }

        let extendSelection = modifiers.contains(.shift)
        let direction = event.keyCode == UInt16(kVK_LeftArrow) ? -1 : 1
        moveByTextBoundary(direction: direction, extendSelection: extendSelection)
        return true
    }

    private func moveByTextBoundary(direction: Int, extendSelection: Bool) {
        let nsText = string as NSString
        let currentRange = selectedRange()
        let anchor = extendSelection ? selectionAnchor(for: currentRange, direction: direction) : NSNotFound
        let current = caretPosition(for: currentRange, direction: direction, extendSelection: extendSelection)
        let next = direction < 0
            ? previousBoundary(in: nsText, from: current)
            : nextBoundary(in: nsText, from: current)

        if extendSelection {
            let start = min(anchor, next)
            setSelectedRange(NSRange(location: start, length: abs(anchor - next)))
        } else {
            setSelectedRange(NSRange(location: next, length: 0))
        }
        scrollRangeToVisible(selectedRange())
    }

    private func selectionAnchor(for range: NSRange, direction: Int) -> Int {
        guard range.length > 0 else { return range.location }
        return direction < 0 ? range.location + range.length : range.location
    }

    private func caretPosition(for range: NSRange, direction: Int, extendSelection: Bool) -> Int {
        guard range.length > 0 else { return range.location }
        if extendSelection {
            return direction < 0 ? range.location : range.location + range.length
        }
        return direction < 0 ? range.location : range.location + range.length
    }

    private func nextBoundary(in text: NSString, from position: Int) -> Int {
        let length = text.length
        guard position < length else { return length }
        let category = characterCategory(text.character(at: position))
        var index = position + 1
        while index < length && characterCategory(text.character(at: index)) == category {
            index += 1
        }
        return index
    }

    private func previousBoundary(in text: NSString, from position: Int) -> Int {
        guard position > 0 else { return 0 }
        var index = position - 1
        let category = characterCategory(text.character(at: index))
        while index > 0 && characterCategory(text.character(at: index - 1)) == category {
            index -= 1
        }
        return index
    }

    private func characterCategory(_ value: unichar) -> Int {
        guard let scalar = UnicodeScalar(Int(value)) else { return 0 }
        if CharacterSet.whitespacesAndNewlines.contains(scalar) {
            return 2
        }
        if CharacterSet.alphanumerics.contains(scalar) {
            return 1
        }
        return 0
    }
}

private final class DialogTabTextView: BoundaryAwareTextView {
    override func insertTab(_ sender: Any?) {
        window?.selectNextKeyView(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        window?.selectPreviousKeyView(sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command),
              !modifiers.contains(.option),
              !modifiers.contains(.control),
              let command = event.charactersIgnoringModifiers?.lowercased()
        else {
            return super.performKeyEquivalent(with: event)
        }

        switch command {
        case "a":
            selectAll(nil)
            return true
        case "x":
            cut(nil)
            return true
        case "c":
            copy(nil)
            return true
        case "v":
            paste(nil)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}

private final class TemplatePreviewButton: NSButton {
    weak var templateTextView: NSTextView?
}

private final class TemplateInsertButton: NSButton {
    weak var templateTextView: NSTextView?
    weak var templateCheckbox: NSButton?
    var templateItems: [TemplateResolver.TemplateItem] = []
}

@MainActor
protocol HistoryWindowControllerDelegate: AnyObject {
    func historyWindow(_ controller: HistoryWindowController, didChoose entry: ClipEntry)
    func historyWindow(_ controller: HistoryWindowController, didChooseUsingEnter entry: ClipEntry)
    func historyWindow(_ controller: HistoryWindowController, didTogglePin entry: ClipEntry)
    func historyWindow(_ controller: HistoryWindowController, didDelete entry: ClipEntry)
    func historyWindow(_ controller: HistoryWindowController, didEdit entry: ClipEntry, name: String, text: String)
    func historyWindow(_ controller: HistoryWindowController, didUpdateProperties entry: ClipEntry, name: String, group: String, text: String, isTemplate: Bool, useQuickCopy: Bool, quickCopyHotkey: HotkeyDescriptor?, quickPasteMode: QuickPasteMode)
    func historyWindow(_ controller: HistoryWindowController, didCopy entries: [ClipEntry])
    func historyWindow(_ controller: HistoryWindowController, didCut entries: [ClipEntry])
    func historyWindow(_ controller: HistoryWindowController, didPushToOtherMachines entries: [ClipEntry])
    func historyWindow(_ controller: HistoryWindowController, didMove entries: [ClipEntry], direction: Int)
    func historyWindowDidRequestPaste(_ controller: HistoryWindowController, after entry: ClipEntry?)
    func historyWindowDidRequestImport(_ controller: HistoryWindowController)
    func historyWindowDidRequestExport(_ controller: HistoryWindowController)
    func historyWindow(_ controller: HistoryWindowController, didCleanURLTracking entries: [ClipEntry])
    func historyWindow(_ controller: HistoryWindowController, didCleanLinksForSharing entries: [ClipEntry])
    func historyWindow(_ controller: HistoryWindowController, didNormalizeLineEndings entries: [ClipEntry], style: LineEndingStyle)
    func historyWindow(_ controller: HistoryWindowController, didSetGroup group: String, for entries: [ClipEntry])
    func historyWindow(_ controller: HistoryWindowController, didChooseFileEvent event: FileClipboardEvent)
    func historyWindow(_ controller: HistoryWindowController, didTogglePinFileEvent event: FileClipboardEvent)
    func historyWindow(_ controller: HistoryWindowController, didDeleteFileEvent event: FileClipboardEvent)
    func historyWindow(_ controller: HistoryWindowController, didCopyFilePaths events: [FileClipboardEvent])
    func historyWindow(_ controller: HistoryWindowController, didRequestGoToFileEvent event: FileClipboardEvent)
    func historyWindow(_ controller: HistoryWindowController, didMoveFileEvents events: [FileClipboardEvent], direction: Int)
    func historyWindowDidRequestClearNormalFileHistory(_ controller: HistoryWindowController)
    func historyWindowDidRequestRemoveUnavailableFileHistory(_ controller: HistoryWindowController)
    func historyWindow(_ controller: HistoryWindowController, didChangeHistoryTab tab: String)
    func historyWindow(_ controller: HistoryWindowController, didChangeSortMode sortMode: String, fileHistory: Bool)
    func historyWindowDidToggleSortDirection(_ controller: HistoryWindowController, fileHistory: Bool)
    func historyWindow(_ controller: HistoryWindowController, didChangeGroupFilter groupFilter: String)
    func historyWindowDidRequestPreferences(_ controller: HistoryWindowController)
    func historyWindowDidRequestManual(_ controller: HistoryWindowController)
    func historyWindowDidRequestUpdateCheck(_ controller: HistoryWindowController)
    func historyWindowDidRequestProjectPage(_ controller: HistoryWindowController)
    func historyWindowDidRequestContact(_ controller: HistoryWindowController)
    func historyWindowDidRequestDonate(_ controller: HistoryWindowController)
    func historyWindowDidRequestDiagnostics(_ controller: HistoryWindowController)
    func historyWindowDidRequestSettingsFolder(_ controller: HistoryWindowController)
    func historyWindowDidRequestSecrets(_ controller: HistoryWindowController)
    func historyWindowDidHide(_ controller: HistoryWindowController)
}

final class HistoryWindow: NSWindow {
    var onEnter: (() -> Void)?
    var onShiftEnter: (() -> Void)?
    var onEscape: (() -> Void)?
    var onFind: (() -> Void)?
    var onFindNext: (() -> Void)?
    var onFindPrevious: (() -> Void)?
    var onBackspace: (() -> Void)?
    var onCommandBackspace: (() -> Void)?
    var onEdit: (() -> Void)?
    var onCopy: (() -> Void)?
    var onCut: (() -> Void)?
    var onPaste: (() -> Void)?
    var onPushToOtherMachines: (() -> Void)?
    var onImport: (() -> Void)?
    var onExport: (() -> Void)?
    var onCleanTracking: (() -> Void)?
    var onCleanForSharing: (() -> Void)?
    var onGroup: (() -> Void)?
    var onGroupFilter: (() -> Void)?
    var onGroupFilterPosition: ((Int) -> Void)?
    var onGoToFile: (() -> Void)?
    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?
    var onSwitchMode: ((Int) -> Void)?
    var onPinnedShortcut: ((Int) -> Void)?
    var onActionsMenu: (() -> Void)?
    var onView: (() -> Void)?
    var onManual: (() -> Void)?
    var onUpdateCheck: (() -> Void)?
    var onProjectPage: (() -> Void)?
    var onDiagnostics: (() -> Void)?
    var onSecrets: (() -> Void)?
    var onFirstRow: (() -> Void)?
    var onLastRow: (() -> Void)?
    var onPageUp: (() -> Void)?
    var onPageDown: (() -> Void)?
    var onHide: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if handleClipmanShortcut(event) { return }
        if handleWindowCommand(event) { return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleClipmanShortcut(event) { return true }
        if handleListNavigationShortcut(event) { return true }
        if handleFunctionKeyShortcut(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    private func handleClipmanShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if let digitIndex = Self.digitIndex(for: event.keyCode) {
            if modifiers == [.command] {
                onPinnedShortcut?(digitIndex)
                return true
            }
            if modifiers == [.control], digitIndex >= 0 && digitIndex <= 2 {
                onSwitchMode?(digitIndex)
                return true
            }
            if modifiers == [.option] {
                onGroupFilterPosition?(digitIndex)
                return true
            }
        }
        if event.keyCode == UInt16(kVK_ANSI_M), modifiers == [.option] {
            onActionsMenu?()
            return true
        }
        if event.keyCode == UInt16(kVK_ANSI_G), modifiers == [.command] {
            onGroup?()
            return true
        }
        if event.keyCode == UInt16(kVK_ANSI_G), modifiers == [.option] {
            onGroupFilter?()
            return true
        }
        if event.keyCode == UInt16(kVK_ANSI_E), modifiers == [.command, .shift] {
            onSecrets?()
            return true
        }
        if event.keyCode == UInt16(kVK_UpArrow), modifiers == [.option] {
            onMoveUp?()
            return true
        }
        if event.keyCode == UInt16(kVK_DownArrow), modifiers == [.option] {
            onMoveDown?()
            return true
        }
        return false
    }

    private func handleListNavigationShortcut(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else {
            return false
        }
        if event.keyCode == UInt16(kVK_Home) {
            onFirstRow?()
            return true
        }
        if event.keyCode == UInt16(kVK_End) {
            onLastRow?()
            return true
        }
        if event.keyCode == UInt16(kVK_PageUp) {
            onPageUp?()
            return true
        }
        if event.keyCode == UInt16(kVK_PageDown) {
            onPageDown?()
            return true
        }
        return false
    }

    private func handleFunctionKeyShortcut(_ event: NSEvent) -> Bool {
        if event.keyCode == UInt16(kVK_F1) {
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if modifiers == [.command] || modifiers == [.control] {
                onProjectPage?()
            } else if modifiers == [.option] {
                onDiagnostics?()
            } else if modifiers == [.shift] {
                onUpdateCheck?()
            } else if modifiers.isEmpty {
                onManual?()
            } else {
                return false
            }
            return true
        }
        if event.keyCode == UInt16(kVK_F3) {
            let commandModifiers = event.modifierFlags.intersection([.command, .control, .option])
            guard commandModifiers.isEmpty else { return false }
            if event.modifierFlags.contains(.shift) {
                onFindPrevious?()
            } else {
                onFindNext?()
            }
            return true
        }
        if event.keyCode == UInt16(kVK_F4) {
            guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else {
                return false
            }
            onView?()
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
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == UInt16(kVK_Return) {
            if modifiers == [.shift] {
                onShiftEnter?()
                return true
            }
            if modifiers == [.command] {
                onGoToFile?()
                return true
            }
            guard modifiers.isEmpty else {
                return false
            }
            onEnter?()
            return true
        }
        if event.keyCode == UInt16(kVK_Escape) {
            onEscape?()
            return true
        }
        if event.keyCode == UInt16(kVK_ANSI_F), modifiers == [.command] {
            onFind?()
            return true
        }
        if event.keyCode == UInt16(kVK_ANSI_I), modifiers == [.command] {
            onImport?()
            return true
        }
        if event.keyCode == UInt16(kVK_ANSI_E), modifiers == [.command] {
            onExport?()
            return true
        }
        if event.keyCode == UInt16(kVK_ANSI_R), modifiers == [.command, .shift] {
            onCleanTracking?()
            return true
        }
        if event.keyCode == UInt16(kVK_ANSI_S), modifiers == [.command, .shift] {
            onCleanForSharing?()
            return true
        }
        if handleFunctionKeyShortcut(event) { return true }
        if event.keyCode == UInt16(kVK_Delete) {
            if modifiers == [.command] || modifiers == [.control] || modifiers == [.option] {
                onCommandBackspace?()
            } else if modifiers.isEmpty {
                onBackspace?()
            } else {
                return false
            }
            return true
        }
        if event.keyCode == UInt16(kVK_ForwardDelete) {
            guard modifiers.isEmpty || modifiers == [.command] else { return false }
            onCommandBackspace?()
            return true
        }
        if event.keyCode == UInt16(kVK_F2),
           modifiers.isEmpty {
            onEdit?()
            return true
        }
        if event.keyCode == UInt16(kVK_ANSI_C), modifiers == [.command] {
            onCopy?()
            return true
        }
        if event.keyCode == UInt16(kVK_ANSI_X), modifiers == [.command] {
            onCut?()
            return true
        }
        if event.keyCode == UInt16(kVK_ANSI_V), modifiers == [.command] {
            onPaste?()
            return true
        }
        if event.keyCode == UInt16(kVK_ANSI_P), modifiers == [.command] {
            onPushToOtherMachines?()
            return true
        }
        if handleListNavigationShortcut(event) { return true }
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
    private enum Mode {
        case text
        case links
        case files

        var tabID: String {
            switch self {
            case .text: return HistoryTabID.text
            case .links: return HistoryTabID.links
            case .files: return HistoryTabID.files
            }
        }
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
    private let modeControl = NSSegmentedControl()
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
    private var linksHistoryEnabled = false
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
    private var rememberedTextSelectionID: String?
    private var rememberedTextSelectionRow: Int?
    private var rememberedFileSelectionID: String?
    private var rememberedFileSelectionRow: Int?
    private var showHistoryHotkey: HotkeyDescriptor?
    private var toggleMonitoringHotkey: HotkeyDescriptor?
    private var quickCopyHotkeys: [String: HotkeyDescriptor] = [:]
    private var quickPasteModes: [String: String] = [:]
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
        window.onEnter = { [weak self] in self?.chooseSelectedEntry(triggeredByEnter: true) }
        window.onShiftEnter = { [weak self] in self?.toggleSelectedPin() }
        window.onEscape = { [weak self] in (self?.window as? HistoryWindow)?.hide() }
        window.onFind = { [weak self] in self?.focusSearch() }
        window.onFindNext = { [weak self] in self?.selectSearchResult(direction: 1) }
        window.onFindPrevious = { [weak self] in self?.selectSearchResult(direction: -1) }
        window.onBackspace = { [weak self] in self?.jumpToFirstNormalEntry() }
        window.onCommandBackspace = { [weak self] in self?.deleteSelectedEntry() }
        window.onEdit = { [weak self] in self?.editSelectedEntry() }
        window.onView = { [weak self] in self?.viewSelectedItem() }
        window.onCopy = { [weak self] in self?.copySelectedEntries() }
        window.onCut = { [weak self] in self?.cutSelectedEntries() }
        window.onPaste = { [weak self] in self?.pasteAfterSelectedEntry() }
        window.onPushToOtherMachines = { [weak self] in self?.pushSelectedToOtherMachines() }
        window.onImport = { [weak self] in self?.requestImport() }
        window.onExport = { [weak self] in self?.requestExport() }
        window.onCleanTracking = { [weak self] in self?.cleanSelectedEntriesForTracking() }
        window.onCleanForSharing = { [weak self] in self?.cleanSelectedEntriesForSharing() }
        window.onGroup = { [weak self] in self?.groupSelectedEntries() }
        window.onGroupFilter = { [weak self] in self?.showGroupFilterMenu() }
        window.onGroupFilterPosition = { [weak self] index in self?.applyGroupFilter(at: index) }
        window.onGoToFile = { [weak self] in self?.goToSelectedFileEvent() }
        window.onMoveUp = { [weak self] in self?.moveSelectedItems(direction: -1) }
        window.onMoveDown = { [weak self] in self?.moveSelectedItems(direction: 1) }
        window.onSwitchMode = { [weak self] index in
            guard let self else { return }
            self.setMode(self.modeForVisibleSegment(index), notify: true)
        }
        window.onPinnedShortcut = { [weak self] index in self?.activatePinnedShortcut(index: index) }
        window.onActionsMenu = { [weak self] in self?.showActionsMenu() }
        window.onManual = { [weak self] in
            guard let self else { return }
            self.historyDelegate?.historyWindowDidRequestManual(self)
        }
        window.onUpdateCheck = { [weak self] in
            guard let self else { return }
            self.historyDelegate?.historyWindowDidRequestUpdateCheck(self)
        }
        window.onProjectPage = { [weak self] in
            guard let self else { return }
            self.historyDelegate?.historyWindowDidRequestProjectPage(self)
        }
        window.onDiagnostics = { [weak self] in
            guard let self else { return }
            self.historyDelegate?.historyWindowDidRequestDiagnostics(self)
        }
        window.onSecrets = { [weak self] in
            guard let self else { return }
            self.historyDelegate?.historyWindowDidRequestSecrets(self)
        }
        window.onFirstRow = { [weak self] in self?.selectBoundaryRow(first: true) }
        window.onLastRow = { [weak self] in self?.selectBoundaryRow(first: false) }
        window.onPageUp = { [weak self] in self?.selectPage(direction: -1) }
        window.onPageDown = { [weak self] in self?.selectPage(direction: 1) }
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

    var isHistoryVisible: Bool {
        window?.isVisible == true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(entries: [ClipEntry]) {
        rememberSelectionForCurrentMode()
        let selectedID = mode != .files ? selectedID() : rememberedTextSelectionID
        allEntries = entries
        applyFilter(preferredSelectedID: selectedID)
    }

    func update(fileEvents: [FileClipboardEvent]) {
        rememberSelectionForCurrentMode()
        let selectedID = mode == .files ? selectedID() : rememberedFileSelectionID
        allFileEvents = fileEvents
        applyFilter(preferredSelectedID: selectedID)
    }

    func showFileHistory() {
        setMode(.files, notify: true)
    }

    func showHistoryTab(_ tabID: String) {
        setMode(modeForTabID(tabID), notify: false)
    }

    func configureSort(textSortMode: String, textDescending: Bool, fileSortMode: String, fileDescending: Bool, selectedTab: Int, selectedHistoryTab: String, linksHistoryEnabled: Bool, groupFilter: String) {
        self.textSortMode = textSortMode
        self.textSortDescending = textDescending
        self.fileSortMode = fileSortMode
        self.fileSortDescending = fileDescending
        self.groupFilter = groupFilter.isEmpty ? "All" : groupFilter
        self.linksHistoryEnabled = linksHistoryEnabled
        mode = modeForTabID(HistoryTabID.normalize(selectedHistoryTab.isEmpty ? (selectedTab == 1 ? HistoryTabID.files : HistoryTabID.text) : selectedHistoryTab, linksEnabled: linksHistoryEnabled))
        configureModeControl()
        updateToolbarState()
        applyFilter(preferredSelectedID: rememberedSelectionID(for: mode))
    }

    func configureQuickCopy(showHistoryHotkey: HotkeyDescriptor, toggleMonitoringHotkey: HotkeyDescriptor, quickCopyHotkeys: [String: HotkeyDescriptor], quickPasteModes: [String: String]) {
        self.showHistoryHotkey = showHistoryHotkey
        self.toggleMonitoringHotkey = toggleMonitoringHotkey
        self.quickCopyHotkeys = quickCopyHotkeys
        self.quickPasteModes = quickPasteModes
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        focusHistoryWindow(sender)
        if tableView.selectedRow < 0 && !filteredEntries.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    func focusHistoryWindow(_ sender: Any?) {
        guard let window else { return }
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
        focusHistoryTable()
        beginDelayedFocusAttempts()
    }

    private func beginDelayedFocusAttempts() {
        for delay in [0.08, 0.25, 0.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self,
                      let window = self.window,
                      window.isVisible
                else { return }
                NSApp.activate(ignoringOtherApps: true)
                window.orderFrontRegardless()
                window.makeKeyAndOrderFront(nil)
                self.focusHistoryTable()
            }
        }
    }

    private func focusHistoryTable() {
        guard let window else { return }
        window.makeFirstResponder(tableView)
        if tableView.selectedRow < 0,
           let row = firstSelectableRow(startingAt: 0) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        NSAccessibility.post(element: tableView, notification: .focusedUIElementChanged)
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

        configureModeControl()
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
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

    private func visibleModes() -> [Mode] {
        linksHistoryEnabled ? [.text, .links, .files] : [.text, .files]
    }

    private func modeForVisibleSegment(_ index: Int) -> Mode {
        let modes = visibleModes()
        guard modes.indices.contains(index) else { return .text }
        return modes[index]
    }

    private func modeForTabID(_ tabID: String) -> Mode {
        if tabID.caseInsensitiveCompare(HistoryTabID.files) == .orderedSame { return .files }
        if linksHistoryEnabled, tabID.caseInsensitiveCompare(HistoryTabID.links) == .orderedSame { return .links }
        return .text
    }

    private func configureModeControl() {
        let modes = visibleModes()
        modeControl.trackingMode = .selectOne
        modeControl.segmentCount = modes.count
        for (index, visibleMode) in modes.enumerated() {
            modeControl.setLabel(modeTitle(for: visibleMode), forSegment: index)
            modeControl.setWidth(130, forSegment: index)
            modeControl.setToolTip(modeTitle(for: visibleMode), forSegment: index)
        }
        if let selected = modes.firstIndex(of: mode) {
            modeControl.selectedSegment = selected
        } else {
            mode = .text
            modeControl.selectedSegment = 0
        }
        modeControl.setAccessibilityLabel(linksHistoryEnabled
            ? "History type. Text History, Control+1. Links History, Control+2. File History, Control+3."
            : "History type. Text History, Control+1. File History, Control+2.")
    }

    private func modeTitle(for mode: Mode) -> String {
        switch mode {
        case .text: return "Text History"
        case .links: return "Links History"
        case .files: return "File History"
        }
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
        let textMode = mode != .files
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
        sortButton.setAccessibilityLabel("Sort \(modeTitle(for: mode).lowercased()), current sort \(selectedSort)")

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

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === searchField else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            focusHistoryTable()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            searchField.stringValue = ""
            searchChanged()
            focusHistoryTable()
            return true
        }
        return false
    }

    @objc private func modeChanged() {
        setMode(modeForVisibleSegment(modeControl.selectedSegment), notify: true)
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
        guard newMode != mode else {
            tableView.window?.makeFirstResponder(tableView)
            return
        }
        rememberSelectionForCurrentMode()
        mode = newMode
        configureModeControl()
        updateTableAccessibility()
        updateToolbarState()
        applyFilter(preferredSelectedID: rememberedSelectionID(for: newMode))
        if notify {
            historyDelegate?.historyWindow(self, didChangeHistoryTab: mode.tabID)
        }
        tableView.window?.makeFirstResponder(tableView)
    }

    private func applyFilter(preferredSelectedID: String?) {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch mode {
        case .text, .links:
            let linkMode = mode == .links
            let tabEntries = linksHistoryEnabled
                ? allEntries.filter { LinkClassifier.isLinkOnlyText($0.Text) == linkMode }
                : allEntries
            let grouped = filterEntriesByGroup(tabEntries)
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
            tableView.scrollRowToVisible(index)
        } else if let preferredRowAfterReload {
            self.preferredRowAfterReload = nil
            let clamped = max(0, min(preferredRowAfterReload, rows.count - 1))
            if let selectable = firstSelectableRow(startingAt: clamped) {
                tableView.selectRowIndexes(IndexSet(integer: selectable), byExtendingSelection: false)
                tableView.scrollRowToVisible(selectable)
            }
        } else if let rememberedRow = rememberedSelectionRow(for: mode), !rows.isEmpty {
            let clamped = max(0, min(rememberedRow, rows.count - 1))
            let selectedRow = firstSelectableRow(startingAt: clamped) ?? firstSelectableRow(startingAt: 0) ?? 0
            tableView.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
            tableView.scrollRowToVisible(selectedRow)
        } else if !rows.isEmpty {
            let selectedRow = firstSelectableRow(startingAt: min(max(tableView.selectedRow, 0), rows.count - 1)) ?? firstSelectableRow(startingAt: 0) ?? 0
            tableView.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
        }
        rememberSelectionForCurrentMode()
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
        case .text, .links:
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

    private func rememberSelectionForCurrentMode() {
        let row = tableView.selectedRow
        let id = selectedID()
        switch mode {
        case .text, .links:
            rememberedTextSelectionID = id
            rememberedTextSelectionRow = row >= 0 ? row : nil
        case .files:
            rememberedFileSelectionID = id
            rememberedFileSelectionRow = row >= 0 ? row : nil
        }
    }

    private func rememberedSelectionID(for mode: Mode) -> String? {
        switch mode {
        case .text, .links: return rememberedTextSelectionID
        case .files: return rememberedFileSelectionID
        }
    }

    private func rememberedSelectionRow(for mode: Mode) -> Int? {
        switch mode {
        case .text, .links: return rememberedTextSelectionRow
        case .files: return rememberedFileSelectionRow
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
        tableView.setAccessibilityLabel(modeTitle(for: mode))
        tableView.tableColumns.first?.title = modeTitle(for: mode)
    }

    private func showActionsMenu() {
        let menu = NSMenu(title: "Clipman")
        addMenuItem("Choose Selected", action: #selector(menuChooseSelected), to: menu, shortcut: "Enter")
        addMenuItem(mode == .files ? "Copy Selected Paths" : "Copy Selected", action: #selector(menuCopySelected), to: menu, shortcut: "Command+C")
        if mode != .files {
            addMenuItem("Cut Selected", action: #selector(menuCutSelected), to: menu, shortcut: "Command+X")
            addMenuItem("Paste After Selected", action: #selector(menuPasteAfterSelected), to: menu, shortcut: "Command+V")
            addMenuItem("Entry Properties", action: #selector(menuEditSelected), to: menu, shortcut: "F2")
            addMenuItem("View Selected Text", action: #selector(menuViewSelected), to: menu, shortcut: "F4")
            addMenuItem("Set As Quick Paste Target...", action: #selector(menuSetQuickCopyTarget), to: menu)
            addMenuItem("Push To Other Machines", action: #selector(menuPushToOtherMachines), to: menu, shortcut: "Command+P")
            addQuickPasteTargetItems(to: menu)
        } else {
            addMenuItem("View File Event Details", action: #selector(menuViewSelected), to: menu, shortcut: "F4")
        }
        addMenuItem("Pin or Unpin Selected", action: #selector(menuTogglePin), to: menu, shortcut: "Shift+Enter")
        addMenuItem("Delete Selected", action: #selector(menuDeleteSelected), to: menu, shortcut: "Command+Backspace")
        addMenuItem("Move Up", action: #selector(menuMoveUp), to: menu, shortcut: "Option+Up")
        addMenuItem("Move Down", action: #selector(menuMoveDown), to: menu, shortcut: "Option+Down")
        menu.addItem(.separator())
        addMenuItem("Import Clipboard Entries...", action: #selector(menuImport), to: menu, shortcut: "Command+I")
        addMenuItem("Export Clipboard Entries...", action: #selector(menuExport), to: menu, shortcut: "Command+E")
        if mode == .files {
            addMenuItem("Go To File", action: #selector(menuGoToFile), to: menu, shortcut: "Command+Enter")
        }
        menu.addItem(.separator())
        if mode != .files {
            addMenuItem("Remove URL Tracking", action: #selector(menuCleanTracking), to: menu, shortcut: "Command+Shift+R")
            addMenuItem("Clean Link For Sharing", action: #selector(menuCleanForSharing), to: menu, shortcut: "Command+Shift+S")
            addLineEndingItems(to: menu)
            menu.addItem(.separator())
            addMenuItem("Group Selected...", action: #selector(menuGroupSelected), to: menu, shortcut: "Command+G")
            if !isReservedGroupFilter(groupFilter) {
                addMenuItem("Set Selected to \(groupFilter)", action: #selector(menuGroupSelectedToCurrentFilter), to: menu)
            }
            addGroupFilterItems(to: menu)
            menu.addItem(.separator())
        }
        addMenuItem("Text History", action: #selector(menuTextHistory), to: menu, shortcut: "Control+1").state = mode == .text ? .on : .off
        if linksHistoryEnabled {
            addMenuItem("Links History", action: #selector(menuLinksHistory), to: menu, shortcut: "Control+2").state = mode == .links ? .on : .off
            addMenuItem("File History", action: #selector(menuFileHistory), to: menu, shortcut: "Control+3").state = mode == .files ? .on : .off
        } else {
            addMenuItem("File History", action: #selector(menuFileHistory), to: menu, shortcut: "Control+2").state = mode == .files ? .on : .off
        }
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
        addMenuItem("Find Next", action: #selector(menuFindNext), to: menu, shortcut: "F3")
        addMenuItem("Find Previous", action: #selector(menuFindPrevious), to: menu, shortcut: "Shift+F3")
        addMenuItem("Preferences...", action: #selector(menuPreferences), to: menu, shortcut: "Command+,")
        addMenuItem("Secrets...", action: #selector(menuSecrets), to: menu, shortcut: "Command+Shift+E")
        addMenuItem("Manual", action: #selector(menuManual), to: menu, shortcut: "F1")
        addMenuItem("Check for Updates...", action: #selector(menuCheckForUpdates), to: menu, shortcut: "Shift+F1")
        addMenuItem("Project Page", action: #selector(menuProjectPage), to: menu, shortcut: "Command+F1")
        addMenuItem("Contact", action: #selector(menuContact), to: menu)
        addMenuItem("Donate", action: #selector(menuDonate), to: menu)
        addMenuItem("Diagnostics", action: #selector(menuDiagnostics), to: menu, shortcut: "Option+F1")
        addMenuItem("Open Settings Folder", action: #selector(menuOpenSettingsFolder), to: menu)
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
        guard mode != .files else {
            setMode(.text, notify: true)
            return
        }
        let menu = NSMenu(title: "Group Filter")
        for (index, group) in groupFilterItems().enumerated() {
            if index == reservedGroupFilterItems().count {
                menu.addItem(.separator())
            }
            let shortcut = groupShortcutLabel(index: index)
            let item = addMenuItem(group, action: #selector(menuGroupFilterChanged(_:)), to: menu, shortcut: shortcut)
            item.representedObject = group
            item.state = group.caseInsensitiveCompare(groupFilter) == .orderedSame ? .on : .off
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: actionsButton.bounds.height + 2), in: actionsButton)
    }

    private func addGroupFilterItems(to menu: NSMenu) {
        let groupMenu = NSMenu(title: "Group Filter")
        for (index, group) in groupFilterItems().enumerated() {
            if index == reservedGroupFilterItems().count {
                groupMenu.addItem(.separator())
            }
            let shortcut = groupShortcutLabel(index: index)
            let item = addMenuItem(group, action: #selector(menuGroupFilterChanged(_:)), to: groupMenu, shortcut: shortcut)
            item.representedObject = group
            item.state = group.caseInsensitiveCompare(groupFilter) == .orderedSame ? .on : .off
        }
        let root = NSMenuItem(title: "Group Filter\tOption+G", action: nil, keyEquivalent: "")
        root.submenu = groupMenu
        menu.addItem(root)
    }

    private func addQuickPasteTargetItems(to menu: NSMenu) {
        let targetMenu = NSMenu(title: "Quick Paste Targets")
        let targets = quickPasteTargets()
        if targets.isEmpty {
            let empty = NSMenuItem(title: "No Quick Paste targets assigned", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            targetMenu.addItem(empty)
        } else {
            for target in targets {
                let item = addMenuItem(quickPasteTargetMenuTitle(entry: target.entry, hotkey: target.hotkey, mode: target.mode), action: #selector(menuQuickPasteTargetSelected(_:)), to: targetMenu)
                item.representedObject = target.entry.Id
            }
        }
        let root = NSMenuItem(title: "Quick Paste Targets", action: nil, keyEquivalent: "")
        root.submenu = targetMenu
        menu.addItem(root)
    }

    private func addLineEndingItems(to menu: NSMenu) {
        let lineMenu = NSMenu(title: "Line Endings")
        addMenuItem("Convert To Windows CRLF", action: #selector(menuNormalizeLineEndingsWindows), to: lineMenu)
        addMenuItem("Convert To Unix LF", action: #selector(menuNormalizeLineEndingsUnix), to: lineMenu)
        addMenuItem("Convert To Old Mac CR", action: #selector(menuNormalizeLineEndingsOldMac), to: lineMenu)
        let root = NSMenuItem(title: "Line Endings", action: nil, keyEquivalent: "")
        root.submenu = lineMenu
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
        case .text, .links: return filteredEntries.filter(\.Pinned).map(Row.entry)
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
    @objc private func menuImport() { requestImport() }
    @objc private func menuExport() { requestExport() }
    @objc private func menuCleanTracking() { cleanSelectedEntriesForTracking() }
    @objc private func menuCleanForSharing() { cleanSelectedEntriesForSharing() }
    @objc private func menuNormalizeLineEndingsWindows() { normalizeSelectedLineEndings(.windows) }
    @objc private func menuNormalizeLineEndingsUnix() { normalizeSelectedLineEndings(.unix) }
    @objc private func menuNormalizeLineEndingsOldMac() { normalizeSelectedLineEndings(.oldMac) }
    @objc private func menuGoToFile() { goToSelectedFileEvent() }
    @objc private func menuEditSelected() { editSelectedEntry() }
    @objc private func menuViewSelected() { viewSelectedItem() }
    @objc private func menuSetQuickCopyTarget() { setQuickCopyTarget() }
    @objc private func menuPushToOtherMachines() { pushSelectedToOtherMachines() }
    @objc private func menuQuickPasteTargetSelected(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        focusEntry(id: id)
    }
    @objc private func menuGroupSelected() { groupSelectedEntries() }
    @objc private func menuGroupSelectedToCurrentFilter() { groupSelectedEntriesToCurrentFilter() }
    @objc private func menuTogglePin() { toggleSelectedPin() }
    @objc private func menuDeleteSelected() { deleteSelectedEntry() }
    @objc private func menuMoveUp() { moveSelectedItems(direction: -1) }
    @objc private func menuMoveDown() { moveSelectedItems(direction: 1) }
    @objc private func menuTextHistory() { setMode(.text, notify: true) }
    @objc private func menuLinksHistory() { setMode(.links, notify: true) }
    @objc private func menuFileHistory() { setMode(.files, notify: true) }
    @objc private func menuJumpToNormal() { jumpToFirstNormalEntry() }
    @objc private func menuFind() { focusSearch() }
    @objc private func menuFindNext() { selectSearchResult(direction: 1) }
    @objc private func menuFindPrevious() { selectSearchResult(direction: -1) }
    @objc private func menuPreferences() { historyDelegate?.historyWindowDidRequestPreferences(self) }
    @objc private func menuSecrets() { historyDelegate?.historyWindowDidRequestSecrets(self) }
    @objc private func menuManual() { historyDelegate?.historyWindowDidRequestManual(self) }
    @objc private func menuCheckForUpdates() { historyDelegate?.historyWindowDidRequestUpdateCheck(self) }
    @objc private func menuProjectPage() { historyDelegate?.historyWindowDidRequestProjectPage(self) }
    @objc private func menuContact() { historyDelegate?.historyWindowDidRequestContact(self) }
    @objc private func menuDonate() { historyDelegate?.historyWindowDidRequestDonate(self) }
    @objc private func menuDiagnostics() { historyDelegate?.historyWindowDidRequestDiagnostics(self) }
    @objc private func menuOpenSettingsFolder() { historyDelegate?.historyWindowDidRequestSettingsFolder(self) }
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
        guard mode != .files else {
            setMode(.text, notify: true)
            return
        }
        let groups = groupFilterItems()
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
        rememberSelectionForCurrentMode()
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

    private func chooseSelectedEntry(triggeredByEnter: Bool = false) {
        if let entry = selectedEntry() {
            if triggeredByEnter {
                historyDelegate?.historyWindow(self, didChooseUsingEnter: entry)
            } else {
                historyDelegate?.historyWindow(self, didChoose: entry)
            }
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
        case .text, .links:
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
        showEntryProperties(entry: entry, quickCopyOnly: false)
    }

    private func viewSelectedItem() {
        if let entry = selectedEntry() {
            showReadOnlyText(
                title: "Clipboard Entry Text",
                accessibilityLabel: "Selected clipboard entry text",
                text: entry.Text,
                details: clipboardEntryDetails(entry)
            )
            return
        }

        if let event = selectedFileEvent() {
            var lines: [String] = [
                "Operation: \(event.Operation.isEmpty ? "Copy" : event.Operation)",
                "File count: \(event.FileCount)",
                "Contains text: \(event.ContainsText ? "Yes" : "No")"
            ]
            if !event.Source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append("Source: \(event.Source)")
            }
            if !event.SourceMachine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append("Machine: \(event.SourceMachine)")
            }
            if event.CapturedUnixMs > 0 {
                let date = Date(timeIntervalSince1970: TimeInterval(event.CapturedUnixMs) / 1000.0)
                lines.append("Captured: \(dateFormatter.string(from: date))")
            }
            if event.Pinned {
                lines.append("Pinned: Yes")
            }
            if !event.Formats.isEmpty {
                lines.append("")
                lines.append("Formats:")
                lines.append(contentsOf: event.Formats.map { "- \($0)" })
            }
            if !event.Files.isEmpty {
                lines.append("")
                lines.append("Files:")
                lines.append(contentsOf: event.Files.map { "- \($0)" })
            }
            showReadOnlyText(title: "File Event Details", accessibilityLabel: "Selected file history event details", text: lines.joined(separator: "\n"))
            return
        }

        NSSound.beep()
    }

    private func clipboardEntryDetails(_ entry: ClipEntry) -> [(String, String)] {
        var details: [(String, String)] = []
        addDetail(&details, "Name", entry.Name)
        addDetail(&details, "Group", entry.Group)
        addDetail(&details, "Machine", entry.SourceMachine)
        details.append(("Pinned", entry.Pinned ? "Yes" : "No"))
        details.append(("Template", entry.IsTemplate ? "Yes" : "No"))
        if entry.CreatedUnixMs > 0 {
            let date = Date(timeIntervalSince1970: TimeInterval(entry.CreatedUnixMs) / 1000.0)
            details.append(("Added", dateFormatter.string(from: date)))
        }
        if entry.LastUsedUnixMs > 0 {
            let date = Date(timeIntervalSince1970: TimeInterval(entry.LastUsedUnixMs) / 1000.0)
            details.append(("Last used", dateFormatter.string(from: date)))
        }
        if entry.ManualOrder > 0 {
            details.append(("Manual order", String(entry.ManualOrder)))
        }
        details.append(("Text length", String(entry.Text.count)))
        details.append(("Links", String(countLinks(in: entry.Text))))
        addDetail(&details, "Entry ID", entry.Id)
        return details
    }

    private func addDetail(_ details: inout [(String, String)], _ name: String, _ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            details.append((name, trimmed))
        }
    }

    private func countLinks(in text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s<>'"]+"#, options: [.caseInsensitive]) else {
            return 0
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.numberOfMatches(in: text, options: [], range: range)
    }

    private func showReadOnlyText(title: String, accessibilityLabel: String, text: String, details: [(String, String)] = []) {
        let alert = NSAlert()
        alert.messageText = title
        let closeButton = alert.addButton(withTitle: "Close")
        closeButton.keyEquivalent = "\u{1b}"
        closeButton.keyEquivalentModifierMask = []
        let textView = BoundaryAwareTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 280))
        textView.string = text
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.setAccessibilityLabel(accessibilityLabel)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 280))
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.documentView = textView

        if details.isEmpty {
            alert.accessoryView = scroll
        } else {
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.spacing = 8
            stack.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(scroll)
            scroll.widthAnchor.constraint(equalToConstant: 560).isActive = true
            scroll.heightAnchor.constraint(equalToConstant: 260).isActive = true

            let detailsLabel = NSTextField(labelWithString: "Details")
            detailsLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            stack.addArrangedSubview(detailsLabel)

            let detailsTable = NSTableView()
            detailsTable.headerView = nil
            detailsTable.allowsColumnReordering = false
            detailsTable.allowsColumnResizing = true
            detailsTable.allowsMultipleSelection = false
            detailsTable.setAccessibilityLabel("Entry details")
            let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
            nameColumn.title = "Property"
            nameColumn.width = 160
            let valueColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("value"))
            valueColumn.title = "Value"
            valueColumn.width = 380
            detailsTable.addTableColumn(nameColumn)
            detailsTable.addTableColumn(valueColumn)
            let dataSource = MetadataTableDataSource(rows: details)
            detailsTable.dataSource = dataSource
            detailsTable.delegate = dataSource

            let detailsScroll = NSScrollView()
            detailsScroll.borderType = .bezelBorder
            detailsScroll.hasVerticalScroller = true
            detailsScroll.documentView = detailsTable
            stack.addArrangedSubview(detailsScroll)
            detailsScroll.widthAnchor.constraint(equalToConstant: 560).isActive = true
            detailsScroll.heightAnchor.constraint(equalToConstant: 135).isActive = true

            alert.accessoryView = stack
            alert.window.initialFirstResponder = textView
            alert.layout()
            _ = dataSource
        }
        alert.runModal()
    }

    private func setQuickCopyTarget() {
        guard mode != .files, let entry = selectedEntry() else {
            NSSound.beep()
            return
        }
        showEntryProperties(entry: entry, quickCopyOnly: true)
    }

    private func showEntryProperties(entry: ClipEntry, quickCopyOnly: Bool) {
        let alert = NSAlert()
        alert.messageText = quickCopyOnly ? "Set Quick Paste Target" : "Clipboard Entry Properties"
        alert.informativeText = quickCopyOnly
            ? "Choose whether this entry is pasted by the global Quick Paste hotkey, and set the hotkey if needed."
            : "Edit the entry and choose whether it is pasted by the global Quick Paste hotkey."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let nameField = NSTextField(string: entry.Name)
        nameField.placeholderString = "Name"
        nameField.setAccessibilityLabel("Entry name")
        let groupField = NSTextField(string: entry.Group)
        groupField.placeholderString = "Group"
        groupField.setAccessibilityLabel("Entry group")
        let textView = DialogTabTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 180))
        textView.string = entry.Text
        textView.isRichText = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.setAccessibilityLabel("Clipboard text")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 180))
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.documentView = textView
        let quickCopyCheckbox = NSButton(checkboxWithTitle: "Use this entry for Quick Paste", target: nil, action: nil)
        let templateCheckbox = NSButton(checkboxWithTitle: "Template entry", target: nil, action: nil)
        templateCheckbox.state = entry.IsTemplate ? .on : .off
        templateCheckbox.setAccessibilityLabel("Template entry")
        let existingHotkey = quickCopyHotkeys[entry.Id]
        let existingMode = QuickPasteMode.normalize(quickPasteModes[entry.Id])
        quickCopyCheckbox.state = quickCopyOnly || existingHotkey != nil ? .on : .off
        quickCopyCheckbox.setAccessibilityLabel("Use this entry for Quick Paste")
        let hotkeyField = HotkeyCaptureField()
        hotkeyField.descriptor = existingHotkey
        hotkeyField.setAccessibilityLabel("Quick Paste hotkey")
        let hotkeyLabel = NSTextField(labelWithString: "Quick Paste hotkey")
        let hotkeyRow = NSStackView(views: [hotkeyLabel, hotkeyField])
        hotkeyRow.orientation = .horizontal
        hotkeyRow.spacing = 8
        hotkeyField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        let modeLabel = NSTextField(labelWithString: "Quick Paste mode")
        let pasteRestoreButton = NSButton(radioButtonWithTitle: "Paste and restore previous clipboard", target: nil, action: nil)
        let pasteKeepButton = NSButton(radioButtonWithTitle: "Paste and keep target on clipboard", target: nil, action: nil)
        let copyOnlyButton = NSButton(radioButtonWithTitle: "Copy to clipboard only", target: nil, action: nil)
        let modeRadioGroup = QuickPasteModeRadioGroup(
            pasteRestoreButton: pasteRestoreButton,
            pasteKeepButton: pasteKeepButton,
            copyOnlyButton: copyOnlyButton,
            selectedMode: existingMode
        )
        let modeStack = NSStackView(views: [modeLabel, pasteRestoreButton, pasteKeepButton, copyOnlyButton])
        modeStack.orientation = .vertical
        modeStack.spacing = 4
        modeStack.setAccessibilityLabel("Quick Paste mode")
        let previewTemplateButton = TemplatePreviewButton(title: "Preview template", target: nil, action: nil)
        previewTemplateButton.setAccessibilityLabel("Preview template")
        previewTemplateButton.target = self
        previewTemplateButton.action = #selector(entryPropertiesPreviewTemplate(_:))
        previewTemplateButton.templateTextView = textView
        let insertPresetButton = TemplateInsertButton(title: "Insert sample...", target: nil, action: nil)
        insertPresetButton.setAccessibilityLabel("Insert sample template")
        insertPresetButton.setAccessibilityHelp("Opens a menu of sample templates. The chosen sample is inserted at the cursor in the clipboard text field.")
        insertPresetButton.target = self
        insertPresetButton.action = #selector(entryPropertiesInsertTemplateItem(_:))
        insertPresetButton.templateTextView = textView
        insertPresetButton.templateCheckbox = templateCheckbox
        insertPresetButton.templateItems = TemplateResolver.presets
        let insertVariableButton = TemplateInsertButton(title: "Insert field...", target: nil, action: nil)
        insertVariableButton.setAccessibilityLabel("Insert template field")
        insertVariableButton.setAccessibilityHelp("Opens a menu of template fields. The chosen field is inserted at the cursor in the clipboard text field.")
        insertVariableButton.target = self
        insertVariableButton.action = #selector(entryPropertiesInsertTemplateItem(_:))
        insertVariableButton.templateTextView = textView
        insertVariableButton.templateCheckbox = templateCheckbox
        insertVariableButton.templateItems = TemplateResolver.variables
        let templateVariablesButton = NSButton(title: "Template variables", target: nil, action: nil)
        templateVariablesButton.setAccessibilityLabel("Template variables")
        templateVariablesButton.target = self
        templateVariablesButton.action = #selector(entryPropertiesTemplateVariables(_:))
        let templateButtonRow = NSStackView(views: [insertPresetButton, insertVariableButton, previewTemplateButton, templateVariablesButton])
        templateButtonRow.orientation = .horizontal
        templateButtonRow.spacing = 8

        let views = quickCopyOnly
            ? [quickCopyCheckbox, hotkeyRow, modeStack]
            : [nameField, groupField, scroll, templateCheckbox, templateButtonRow, quickCopyCheckbox, hotkeyRow, modeStack]
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 520, height: quickCopyOnly ? 162 : 438)
        alert.accessoryView = stack

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let selectedMode = modeRadioGroup.selectedMode
        let capturedHotkey = hotkeyField.descriptor ?? HotkeyDescriptor.parse(hotkeyField.stringValue)
        let requestedQuickCopy = quickCopyCheckbox.state == .on
        let useQuickCopy = requestedQuickCopy && capturedHotkey != nil
        if requestedQuickCopy && capturedHotkey == nil && !hotkeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            showPropertyError("Quick Paste needs a valid hotkey.")
            return
        }
        if useQuickCopy {
            guard let capturedHotkey, capturedHotkey.isValid else {
                showPropertyError("Quick Paste needs a valid hotkey.")
                return
            }
            if capturedHotkey == showHistoryHotkey || capturedHotkey == toggleMonitoringHotkey {
                showPropertyError("Quick Paste must use a different hotkey from Show History and Toggle Monitoring.")
                return
            }
            if quickCopyHotkeys.contains(where: { $0.key != entry.Id && $0.value == capturedHotkey }) {
                showPropertyError("Another Quick Paste entry already uses \(capturedHotkey).")
                return
            }
            if capturedHotkey.usesSingleModifier && !confirmSingleModifierQuickPasteHotkey() {
                return
            }
        }
        if quickCopyOnly {
            historyDelegate?.historyWindow(self, didUpdateProperties: entry, name: entry.Name, group: entry.Group, text: entry.Text, isTemplate: entry.IsTemplate, useQuickCopy: useQuickCopy, quickCopyHotkey: capturedHotkey, quickPasteMode: selectedMode)
            return
        }
        historyDelegate?.historyWindow(self, didUpdateProperties: entry, name: nameField.stringValue, group: groupField.stringValue, text: textView.string, isTemplate: templateCheckbox.state == .on, useQuickCopy: useQuickCopy, quickCopyHotkey: capturedHotkey, quickPasteMode: selectedMode)
    }

    @objc private func entryPropertiesPreviewTemplate(_ sender: TemplatePreviewButton) {
        guard let textView = sender.templateTextView else {
            NSSound.beep()
            return
        }
        showReadOnlyText(title: "Template Preview", accessibilityLabel: "Template preview", text: TemplateResolver.resolve(textView.string))
    }

    @objc private func entryPropertiesInsertTemplateItem(_ sender: TemplateInsertButton) {
        guard let textView = sender.templateTextView else {
            NSSound.beep()
            return
        }
        guard let selected = chooseTemplateItem(sender.templateItems, title: sender.title) else {
            textView.window?.makeFirstResponder(textView)
            return
        }
        textView.insertText(selected.text, replacementRange: textView.selectedRange())
        sender.templateCheckbox?.state = .on
        textView.window?.makeFirstResponder(textView)
    }

    private func chooseTemplateItem(_ items: [TemplateResolver.TemplateItem], title: String) -> TemplateResolver.TemplateItem? {
        guard let first = items.first else {
            NSSound.beep()
            return nil
        }

        let alert = NSAlert()
        alert.messageText = title.replacingOccurrences(of: "...", with: "")
        alert.informativeText = "Choose the template text to insert."
        alert.addButton(withTitle: "Insert")
        alert.addButton(withTitle: "Cancel")

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 26), pullsDown: false)
        for item in items {
            popup.addItem(withTitle: item.name)
            popup.lastItem?.representedObject = item.text
        }
        popup.selectItem(at: 0)
        popup.setAccessibilityLabel(title.replacingOccurrences(of: "...", with: ""))
        alert.accessoryView = popup

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let index = popup.indexOfSelectedItem
        guard items.indices.contains(index) else { return first }
        return items[index]
    }

    @objc private func entryPropertiesTemplateVariables(_ sender: NSButton) {
        showReadOnlyText(title: "Template Variables", accessibilityLabel: "Template variables", text: TemplateResolver.variableReferenceText)
    }

    private func confirmSingleModifierQuickPasteHotkey() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Keep single-modifier Quick Paste hotkey?"
        alert.informativeText = "This Quick Paste hotkey uses only one modifier. Clipman allows this for compatibility, but it is more likely to conflict with other apps or keyboard layouts."
        alert.addButton(withTitle: "Keep")
        alert.addButton(withTitle: "Go Back")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showPropertyError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Could Not Save Entry Properties"
        alert.informativeText = message
        alert.runModal()
    }

    private func copySelectedEntries() {
        switch mode {
        case .text, .links:
            let entries = selectedEntries()
            guard !entries.isEmpty else { return }
            historyDelegate?.historyWindow(self, didCopy: entries)
        case .files:
            let events = selectedFileEvents()
            guard !events.isEmpty else { return }
            historyDelegate?.historyWindow(self, didCopyFilePaths: events)
        }
    }

    private func moveSelectedItems(direction: Int) {
        switch mode {
        case .text, .links:
            let entries = selectedEntries()
            guard !entries.isEmpty else {
                NSSound.beep()
                return
            }
            guard let pinned = entries.first?.Pinned,
                  !entries.contains(where: { $0.Pinned != pinned }) else {
                NSSound.beep()
                return
            }
            preferredRowAfterReload = tableView.selectedRowIndexes.min()
            historyDelegate?.historyWindow(self, didMove: entries, direction: direction)
        case .files:
            let events = selectedFileEvents()
            guard !events.isEmpty else {
                NSSound.beep()
                return
            }
            guard let pinned = events.first?.Pinned,
                  !events.contains(where: { $0.Pinned != pinned }) else {
                NSSound.beep()
                return
            }
            preferredRowAfterReload = tableView.selectedRowIndexes.min()
            historyDelegate?.historyWindow(self, didMoveFileEvents: events, direction: direction)
        }
    }

    private func cutSelectedEntries() {
        guard mode != .files else {
            copySelectedEntries()
            return
        }
        let entries = selectedEntries()
        guard !entries.isEmpty else { return }
        preferredRowAfterReload = tableView.selectedRowIndexes.min()
        historyDelegate?.historyWindow(self, didCut: entries)
    }

    private func pushSelectedToOtherMachines() {
        guard mode != .files else {
            NSSound.beep()
            return
        }
        let entries = selectedEntries()
        guard !entries.isEmpty else {
            NSSound.beep()
            return
        }
        preferredRowAfterReload = tableView.selectedRowIndexes.min()
        historyDelegate?.historyWindow(self, didPushToOtherMachines: entries)
    }

    private func groupSelectedEntries() {
        guard mode != .files else {
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
        guard mode != .files, !isReservedGroupFilter(groupFilter) else {
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
        guard mode != .files else {
            NSSound.beep()
            return
        }
        historyDelegate?.historyWindowDidRequestPaste(self, after: selectedEntry())
    }

    private func requestImport() {
        historyDelegate?.historyWindowDidRequestImport(self)
    }

    private func requestExport() {
        historyDelegate?.historyWindowDidRequestExport(self)
    }

    private func cleanSelectedEntriesForTracking() {
        guard mode != .files else {
            NSSound.beep()
            return
        }
        let entries = selectedEntries()
        guard !entries.isEmpty else {
            NSSound.beep()
            return
        }
        historyDelegate?.historyWindow(self, didCleanURLTracking: entries)
    }

    private func cleanSelectedEntriesForSharing() {
        guard mode != .files else {
            NSSound.beep()
            return
        }
        let entries = selectedEntries()
        guard !entries.isEmpty else {
            NSSound.beep()
            return
        }
        historyDelegate?.historyWindow(self, didCleanLinksForSharing: entries)
    }

    private func normalizeSelectedLineEndings(_ style: LineEndingStyle) {
        guard mode != .files else {
            NSSound.beep()
            return
        }
        let entries = selectedEntries()
        guard !entries.isEmpty else {
            NSSound.beep()
            return
        }
        historyDelegate?.historyWindow(self, didNormalizeLineEndings: entries, style: style)
    }

    private func goToSelectedFileEvent() {
        guard mode == .files, let event = selectedFileEvent() else {
            NSSound.beep()
            return
        }
        historyDelegate?.historyWindow(self, didRequestGoToFileEvent: event)
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

    private func selectSearchResult(direction: Int) {
        guard !searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            focusSearch()
            return
        }
        guard !rows.isEmpty else {
            NSSound.beep()
            return
        }
        let current = tableView.selectedRow >= 0 ? tableView.selectedRow : (direction > 0 ? -1 : rows.count)
        var index = current
        for _ in 0..<rows.count {
            index += direction > 0 ? 1 : -1
            if index >= rows.count { index = 0 }
            if index < 0 { index = rows.count - 1 }
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            tableView.scrollRowToVisible(index)
            tableView.window?.makeFirstResponder(tableView)
            return
        }
    }

    private func selectBoundaryRow(first: Bool) {
        guard !rows.isEmpty else {
            NSSound.beep()
            return
        }
        let index = first ? 0 : rows.count - 1
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
        tableView.window?.makeFirstResponder(tableView)
    }

    private func selectPage(direction: Int) {
        guard !rows.isEmpty else {
            NSSound.beep()
            return
        }
        let rowHeight = max(tableView.rowHeight, 1)
        let visibleRows = max(1, Int(scrollView.contentView.bounds.height / rowHeight) - 1)
        let current = tableView.selectedRow >= 0 ? tableView.selectedRow : (direction > 0 ? 0 : rows.count - 1)
        let target = max(0, min(rows.count - 1, current + (direction > 0 ? visibleRows : -visibleRows)))
        tableView.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
        tableView.scrollRowToVisible(target)
        tableView.window?.makeFirstResponder(tableView)
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
            var baseLabel = displayText(for: entry)
            let quickPaste = quickPasteLabel(for: entry)
            if !quickPaste.isEmpty {
                baseLabel = "\(quickPaste): \(baseLabel)"
            }
            let label = pinnedShortcutNumber(for: entry).map { "\($0). \(baseLabel)" } ?? baseLabel
            let metadata = metadataText(for: entry)
            textField.stringValue = metadata.isEmpty ? label : "\(label)\n\(metadata)"
            cell.setAccessibilityLabel(textField.stringValue.replacingOccurrences(of: "\n", with: ", "))
        case .fileEvent(let event):
            textField.font = .systemFont(ofSize: NSFont.systemFontSize)
            textField.textColor = .labelColor
            let baseLabel = fileEventLabel(event)
            let label = pinnedShortcutNumber(for: event).map { "\($0). \(baseLabel)" } ?? baseLabel
            let metadata = fileEventMetadata(event)
            textField.stringValue = metadata.isEmpty ? label : "\(label)\n\(metadata)"
            cell.setAccessibilityLabel(textField.stringValue.replacingOccurrences(of: "\n", with: ", "))
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .separator = rows[row] { return 28 }
        return 56
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        return true
    }

    private func firstSelectableRow(startingAt start: Int) -> Int? {
        guard !rows.isEmpty else { return nil }
        for index in start..<rows.count {
            return index
        }
        for index in stride(from: start, through: 0, by: -1) {
            return index
        }
        return nil
    }

    private func pinnedShortcutNumber(for entry: ClipEntry) -> String? {
        guard entry.Pinned,
              let index = filteredEntries.filter(\.Pinned).firstIndex(where: { $0.Id == entry.Id }),
              index < 10 else {
            return nil
        }
        return index == 9 ? "0" : "\(index + 1)"
    }

    private func pinnedShortcutNumber(for event: FileClipboardEvent) -> String? {
        guard event.Pinned,
              let index = filteredFileEvents.filter(\.Pinned).firstIndex(where: { $0.Id == event.Id }),
              index < 10 else {
            return nil
        }
        return index == 9 ? "0" : "\(index + 1)"
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
        guard mode != .files else { return }
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
        if entry.Pinned {
            parts.append("Pinned: Yes")
        }
        if entry.IsTemplate {
            parts.append("Template: Yes")
        }
        return parts.joined(separator: " - ")
    }

    private func quickPasteLabel(for entry: ClipEntry) -> String {
        guard let hotkey = quickCopyHotkeys[entry.Id] else { return "" }
        return "Quick Paste \(hotkey.description), \(QuickPasteMode.normalize(quickPasteModes[entry.Id]).displayText)"
    }

    private func quickPasteTargets() -> [(entry: ClipEntry, hotkey: HotkeyDescriptor, mode: QuickPasteMode)] {
        quickCopyHotkeys.compactMap { id, hotkey in
            guard let entry = allEntries.first(where: { $0.Id == id }) else { return nil }
            return (entry, hotkey, QuickPasteMode.normalize(quickPasteModes[id]))
        }
        .sorted {
            let hotkeyOrder = $0.hotkey.description.localizedCaseInsensitiveCompare($1.hotkey.description)
            if hotkeyOrder != .orderedSame { return hotkeyOrder == .orderedAscending }
            return displayText(for: $0.entry).localizedCaseInsensitiveCompare(displayText(for: $1.entry)) == .orderedAscending
        }
    }

    private func quickPasteTargetMenuTitle(entry: ClipEntry, hotkey: HotkeyDescriptor, mode: QuickPasteMode) -> String {
        var text = displayText(for: entry)
        if text.count > 60 {
            text = String(text.prefix(57)) + "..."
        }
        return "\(hotkey.description), \(mode.displayText): \(text)"
    }

    private func focusEntry(id: String) {
        if let entry = allEntries.first(where: { $0.Id == id }),
           linksHistoryEnabled,
           LinkClassifier.isLinkOnlyText(entry.Text) {
            setMode(.links, notify: true)
        } else {
            setMode(.text, notify: true)
        }
        if !rows.contains(where: {
            if case .entry(let entry) = $0 { return entry.Id == id }
            return false
        }), groupFilter.caseInsensitiveCompare("All") != .orderedSame {
            setGroupFilter("All")
        }
        applyFilter(preferredSelectedID: id)
        focusHistoryTable()
    }

    private func displayText(for entry: ClipEntry) -> String {
        entry.Name.isEmpty ? entry.Text : "\(entry.Name): \(entry.Text)"
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
        if event.Pinned {
            parts.append("Pinned: Yes")
        }
        return parts.joined(separator: " - ")
    }
}
