import XCTest
@testable import Clipman

final class HistorySortTests: XCTestCase {
    func testManualIsTheDefaultAndInvalidStoredValuesNormalizeToManual() throws {
        let suiteName = "HistorySortTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(SettingsStore.loadHistorySort(from: defaults), .manual)

        defaults.set("not-a-sort-mode", forKey: "historySortMode")
        XCTAssertEqual(SettingsStore.loadHistorySort(from: defaults), .manual)

        defaults.set("  NEWEST  ", forKey: "historySortMode")
        XCTAssertEqual(SettingsStore.loadHistorySort(from: defaults), .newest)
    }

    func testSortSelectionPersistsUsingCanonicalValue() throws {
        let suiteName = "HistorySortTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        SettingsStore.saveHistorySort(.oldest, to: defaults)

        XCTAssertEqual(defaults.string(forKey: "historySortMode"), "oldest")
        XCTAssertEqual(SettingsStore.loadHistorySort(from: defaults), .oldest)
    }

    func testOnlyNormalEntriesChangeBetweenSortModes() {
        let entries = [
            entry("normal-b", text: "Beta", created: 30, used: 300, manualOrder: 2),
            entry("pinned-second", text: "Pinned second", created: 20, used: 500, pinned: true, manualOrder: 2),
            entry("normal-c", text: "charlie", created: 20, used: 100, manualOrder: 1),
            entry("pinned-first", text: "Pinned first", created: 10, used: 10, pinned: true, manualOrder: 1),
            entry("normal-a", text: "Alpha", created: 10, used: 200, manualOrder: 3)
        ]

        XCTAssertEqual(ids(HistoryPresentationSorter.ordered(entries, mode: .manual)), [
            "pinned-first", "pinned-second", "normal-c", "normal-b", "normal-a"
        ])
        XCTAssertEqual(ids(HistoryPresentationSorter.ordered(entries, mode: .newest)), [
            "pinned-first", "pinned-second", "normal-b", "normal-a", "normal-c"
        ])
        XCTAssertEqual(ids(HistoryPresentationSorter.ordered(entries, mode: .oldest)), [
            "pinned-first", "pinned-second", "normal-c", "normal-a", "normal-b"
        ])
        XCTAssertEqual(ids(HistoryPresentationSorter.ordered(entries, mode: .text)), [
            "pinned-first", "pinned-second", "normal-a", "normal-b", "normal-c"
        ])
    }

    func testSortActionLabelsAreExplicitAndOrdered() {
        XCTAssertEqual(HistorySortAccessibilityOrder.sourceModifierModes, [
            .text, .oldest, .newest, .manual
        ])
        XCTAssertEqual(HistorySortAccessibilityOrder.voiceOverPresentedModes.map(\.accessibilityActionLabel), [
            "Set sort to Manual",
            "Set sort to Newest first",
            "Set sort to Oldest first",
            "Set sort to Text"
        ])
        XCTAssertEqual(HistorySortMode.manual.next, .newest)
        XCTAssertEqual(HistorySortMode.newest.next, .oldest)
        XCTAssertEqual(HistorySortMode.oldest.next, .text)
        XCTAssertEqual(HistorySortMode.text.next, .manual)
    }

    private func entry(
        _ id: String,
        text: String,
        created: Int64,
        used: Int64,
        pinned: Bool = false,
        manualOrder: Int64
    ) -> ClipEntry {
        ClipEntry(
            Id: id,
            Text: text,
            CreatedUnixMs: created,
            LastUsedUnixMs: used,
            Pinned: pinned,
            ManualOrder: manualOrder
        )
    }

    private func ids(_ entries: [ClipEntry]) -> [String] {
        entries.map(\.Id)
    }
}
