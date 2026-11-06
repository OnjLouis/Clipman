import AppKit
import XCTest
import ClipmanCore
@testable import Clipman

final class FileHistorySelectionTests: XCTestCase {
    @MainActor func testEnterAndChooseSelectedRestoreEverySelectedEvent() throws {
        _ = NSApplication.shared
        let controller = HistoryWindowController()
        let delegate = FileSelectionDelegate()
        controller.historyDelegate = delegate
        let first = FileClipboardEvent(Files: ["/first", "/shared"], Pinned: true)
        let second = FileClipboardEvent(Files: ["/second", "/shared"], Pinned: true)
        controller.update(fileEvents: [first, second])
        controller.showHistoryTab("files")
        let window = try XCTUnwrap(controller.window as? HistoryWindow)
        defer { window.orderOut(nil) }
        func table(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap { table(in: $0) }.first
        }
        let table = try XCTUnwrap(table(in: try XCTUnwrap(window.contentView)))
        table.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
        XCTAssertEqual(table.selectedRowIndexes, IndexSet([0, 1]))
        window.onEnter?()
        XCTAssertEqual(Set(delegate.restored.map(\.Id)), Set([first.Id, second.Id]))

        delegate.restored = []
        _ = controller.perform(NSSelectorFromString("menuChooseSelected"))
        XCTAssertEqual(Set(delegate.restored.map(\.Id)), Set([first.Id, second.Id]))

        window.onCopy?()
        XCTAssertEqual(Set(delegate.copied.map(\.Id)), Set([first.Id, second.Id]))
        window.onPinnedShortcut?(0)
        XCTAssertEqual(delegate.restored.count, 1, "A pinned shortcut still targets only its own event.")

        delegate.restored = []
        table.deselectAll(nil)
        window.onEnter?()
        XCTAssertTrue(delegate.restored.isEmpty)
    }
}

@MainActor private final class FileSelectionDelegate: HistoryWindowControllerDelegate {
    var restored: [FileClipboardEvent] = []
    var copied: [FileClipboardEvent] = []
    func historyWindow(_ controller: HistoryWindowController, didChooseFileEvents events: [FileClipboardEvent]) { restored = events }
    func historyWindow(_ controller: HistoryWindowController, didCopyFilePaths events: [FileClipboardEvent]) { copied = events }
    func historyWindow(_ controller: HistoryWindowController, didChoose entry: ClipEntry) {}
    func historyWindow(_ controller: HistoryWindowController, didChooseUsingEnter entry: ClipEntry) {}
    func historyWindow(_ controller: HistoryWindowController, didTogglePin entry: ClipEntry) {}
    func historyWindow(_ controller: HistoryWindowController, didDelete entry: ClipEntry) {}
    func historyWindow(_ controller: HistoryWindowController, didEdit entry: ClipEntry, name: String, text: String) {}
    func historyWindow(_ controller: HistoryWindowController, didUpdateProperties entry: ClipEntry, name: String, group: String, text: String, isTemplate: Bool, useQuickCopy: Bool, quickCopyHotkey: HotkeyDescriptor?, quickPasteMode: QuickPasteMode) {}
    func historyWindow(_ controller: HistoryWindowController, didCreateQuickClipWithName name: String, group: String, text: String, isPinned: Bool, isTemplate: Bool) {}
    func historyWindow(_ controller: HistoryWindowController, didCopy entries: [ClipEntry]) {}
    func historyWindow(_ controller: HistoryWindowController, didCopyNameAndContent entries: [ClipEntry]) {}
    func historyWindow(_ controller: HistoryWindowController, didCut entries: [ClipEntry]) {}
    func historyWindow(_ controller: HistoryWindowController, didPushToOtherMachines entries: [ClipEntry]) {}
    func historyWindow(_ controller: HistoryWindowController, didMove entries: [ClipEntry], direction: Int) {}
    func historyWindowDidRequestPaste(_ controller: HistoryWindowController, after entry: ClipEntry?) {}
    func historyWindowDidRequestSaveCurrentClipboard(_ controller: HistoryWindowController) {}
    func historyWindowDidRequestImport(_ controller: HistoryWindowController) {}
    func historyWindowDidRequestExport(_ controller: HistoryWindowController) {}
    func historyWindow(_ controller: HistoryWindowController, didRequestWebsiteTitleFor entry: ClipEntry) {}
    func historyWindow(_ controller: HistoryWindowController, didCleanURLTracking entries: [ClipEntry]) {}
    func historyWindow(_ controller: HistoryWindowController, didCleanLinksForSharing entries: [ClipEntry]) {}
    func historyWindow(_ controller: HistoryWindowController, didNormalizeLineEndings entries: [ClipEntry], style: LineEndingStyle) {}
    func historyWindow(_ controller: HistoryWindowController, didSetGroup group: String, for entries: [ClipEntry]) {}
    func historyWindow(_ controller: HistoryWindowController, didTogglePinFileEvent event: FileClipboardEvent) {}
    func historyWindow(_ controller: HistoryWindowController, didDeleteFileEvent event: FileClipboardEvent) {}
    func historyWindow(_ controller: HistoryWindowController, didRequestGoToFileEvent event: FileClipboardEvent) {}
    func historyWindow(_ controller: HistoryWindowController, didMoveFileEvents events: [FileClipboardEvent], direction: Int) {}
    func historyWindowDidRequestClearNormalFileHistory(_ controller: HistoryWindowController) {}
    func historyWindowDidRequestRemoveUnavailableFileHistory(_ controller: HistoryWindowController) {}
    func historyWindow(_ controller: HistoryWindowController, didChangeHistoryTab tab: String) {}
    func historyWindow(_ controller: HistoryWindowController, didChangeHistoryTabOrder order: [String]) {}
    func historyWindow(_ controller: HistoryWindowController, didChangeSortMode sortMode: String, fileHistory: Bool) {}
    func historyWindowDidToggleSortDirection(_ controller: HistoryWindowController, fileHistory: Bool) {}
    func historyWindow(_ controller: HistoryWindowController, didChangeGroupFilter groupFilter: String) {}
    func historyWindow(_ controller: HistoryWindowController, didChangeDeviceFilter deviceFilter: String) {}
    func historyWindowDidDisableDeletionConfirmation(_ controller: HistoryWindowController) {}
    func historyWindowDidRequestPreferences(_ controller: HistoryWindowController) {}
    func historyWindowDidRequestManual(_ controller: HistoryWindowController) {}
    func historyWindowDidRequestUpdateCheck(_ controller: HistoryWindowController) {}
    func historyWindowDidRequestProjectPage(_ controller: HistoryWindowController) {}
    func historyWindowDidRequestDiagnostics(_ controller: HistoryWindowController) {}
    func historyWindowDidRequestSecrets(_ controller: HistoryWindowController) {}
    func historyWindowDidHide(_ controller: HistoryWindowController) {}
}
