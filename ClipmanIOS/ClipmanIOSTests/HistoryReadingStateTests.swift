import XCTest
import SwiftUI
@testable import Clipman

final class HistoryReadingStateTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClipmanReadingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @MainActor
    private func model(root: URL, entries: [ClipEntry] = []) -> ClipmanAppModel {
        var settings = ClipmanSettings.empty
        settings.linksEnabled = true
        return ClipmanAppModel(
            settings: settings,
            historyRepository: ReadingStateRepository(database: ClipDatabase(Entries: entries)),
            quickClipDraftStore: ClipDraftStore(fileURL: root.appendingPathComponent("quick.json")),
            entryEditDraftStore: ClipDraftStore(fileURL: root.appendingPathComponent("edit.json")),
            readingStateStore: HistoryReadingStateStore(fileURL: root.appendingPathComponent("reading.json"))
        )
    }

    @MainActor
    func testBackgroundAndRelaunchRestoreViewerSectionAndReadingPositionsAfterUnlock() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = ClipEntry(Id: "reading-entry", Text: "Private content", Name: "Private title")
        let app = model(root: root, entries: [entry])
        app.database = ClipDatabase(Entries: [entry])
        app.selectedSection = .links
        app.readingState.historyAnchors["Links"] = "reading-entry-link-0"
        app.readingState.historyFocusID = "link:reading-entry-link-0"
        app.beginViewing(entry)
        app.readingState.viewerAnchor = "text-17"
        app.readingState.viewerFocusID = "text-17"
        app.readingState.showingLargeImage = true
        app.sceneMovedToBackground()
        XCTAssertFalse(app.isUnlocked)
        XCTAssertFalse(app.showingEntryView)
        // UIKit can dismiss the removed sheet after the app has entered its locked state.
        app.closeViewedEntry()

        let restored = model(root: root, entries: [entry])
        XCTAssertFalse(restored.isUnlocked)
        XCTAssertNil(restored.viewedEntry)
        XCTAssertEqual(restored.selectedSection, .links)
        XCTAssertEqual(restored.readingState.historyAnchors["Links"], "reading-entry-link-0")
        restored.sceneBecameActive()
        for _ in 0..<100 where !restored.showingEntryView { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(restored.isUnlocked)
        XCTAssertTrue(restored.showingEntryView)
        XCTAssertEqual(restored.viewedEntry?.Id, entry.Id)
        XCTAssertEqual(restored.readingState.viewerAnchor, "text-17")
        XCTAssertEqual(restored.readingState.viewerFocusID, "text-17")
        XCTAssertTrue(restored.readingState.showingLargeImage)
        let json = try String(contentsOf: root.appendingPathComponent("reading.json"), encoding: .utf8)
        XCTAssertFalse(json.contains(entry.Text))
        XCTAssertFalse(json.contains(entry.Name))
        restored.sceneMovedToBackground()
    }

    @MainActor
    func testExplicitCloseClearsViewerButKeepsHistoryPosition() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = model(root: root)
        app.isUnlocked = true
        app.readingState.historyAnchors["Text"] = "history-row"
        app.beginViewing(ClipEntry(Id: "viewed-row", Text: "Text"))
        app.closeViewedEntry()
        XCTAssertNil(app.viewedEntry)
        XCTAssertNil(app.readingState.viewedEntryID)
        XCTAssertEqual(app.readingState.historyAnchors["Text"], "history-row")
        XCTAssertNil(model(root: root).readingState.viewedEntryID)
    }

    @MainActor
    func testDeletedViewedEntryDoesNotReappearFromPlaintextSnapshot() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = model(root: root)
        app.beginViewing(ClipEntry(Id: "deleted", Text: "Deleted secret"))
        app.sceneMovedToBackground()
        let restored = model(root: root)
        restored.sceneBecameActive()
        for _ in 0..<100 where !restored.isUnlocked { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(restored.isUnlocked)
        XCTAssertFalse(restored.showingEntryView)
        XCTAssertNil(restored.viewedEntry)
        restored.sceneMovedToBackground()
    }

    @MainActor
    func testDisabledSectionAndCorruptStateFallBackSafely() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HistoryReadingStateStore(fileURL: root.appendingPathComponent("reading.json"))
        var state = HistoryReadingState()
        state.section = "Rich Text"
        try store.save(state)
        XCTAssertEqual(model(root: root).selectedSection, .text)
        try Data("broken json".utf8).write(to: store.fileURL)
        XCTAssertEqual(model(root: root).readingState, HistoryReadingState())
    }

    @MainActor
    func testRealListRestoresScrolledRowAndStillAcceptsScrollToBottom() async throws {
        let probe = ReadingListProbe()
        let controller = UIHostingController(rootView: ReadingListFixture(probe: probe))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        for _ in 0..<30 where probe.anchor == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(probe.anchor, "row-60", "Restoration must occur before the initial top row overwrites the saved position")
        probe.bottomRequest += 1
        for _ in 0..<30 where (Int(probe.anchor?.dropFirst(4) ?? "0") ?? 0) < 80 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertGreaterThan(Int(probe.anchor?.dropFirst(4) ?? "0") ?? 0, 80)
    }
}

@MainActor
private final class ReadingListProbe: ObservableObject {
    @Published var bottomRequest = 0
    var anchor: String?
}

private struct ReadingListFixture: View {
    @ObservedObject var probe: ReadingListProbe
    var body: some View {
        RememberedList(
            coordinateSpace: "reading-test",
            rowIDs: (0..<100).map { "row-\($0)" },
            savedAnchor: "row-60",
            bottomRequest: probe.bottomRequest,
            remember: { probe.anchor = $0 }
        ) {
            ForEach(0..<100, id: \.self) { index in
                Text("Entry \(index)").frame(height: 44)
                    .readingPositionRow("row-\(index)", in: "reading-test")
            }
        }
    }
}

private actor ReadingStateRepository: MobileHistoryRepositoryProtocol {
    let database: ClipDatabase
    init(database: ClipDatabase) { self.database = database }
    func loadLocal(password: String) async throws -> ClipDatabase? { database }
    func saveLocal(_ database: ClipDatabase, password: String, backupSettings: ClipmanSettings?) async throws -> String? { nil }
    func synchronize(settings: ClipmanSettings, current: ClipDatabase, localAlreadySaved: Bool) async throws -> MobileSyncResult {
        MobileSyncResult(database: current, revision: "", uploaded: false, backupError: nil)
    }
    func persistMutation(settings: ClipmanSettings, current: ClipDatabase, expectedRevision: String) async throws -> MobileSyncResult {
        MobileSyncResult(database: current, revision: "", uploaded: false, backupError: nil)
    }
}
