import XCTest
@testable import Clipman

final class QuickClipDraftTests: XCTestCase {
    @MainActor
    func testBackgroundingPersistsAndRestoresTheActiveDraft() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipmanQuickClipDraftTests-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("quick-clip-draft.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClipDraftStore(fileURL: url)
        let draft = ClipEntry(Text: "Research in progress", Name: "Trip notes")

        let model = ClipmanAppModel(settings: ClipmanSettings.empty, quickClipDraftStore: store)
        model.beginQuickClip()
        model.updateQuickClipDraft(draft)
        model.sceneMovedToBackground()

        let restored = ClipmanAppModel(settings: ClipmanSettings.empty, quickClipDraftStore: store)
        XCTAssertEqual(restored.quickClipDraft, draft)
    }

    func testDraftRoundTripsAndClearsFromPrivateStorage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipmanQuickClipDraftTests-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("quick-clip-draft.json")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ClipDraftStore(fileURL: url)
        let draft = ClipEntry(
            Id: "draft-id",
            Text: "First line\nResearch still to add",
            Name: "Holiday notes",
            Group: "Personal",
            Pinned: true
        )

        try store.save(draft)
        XCTAssertEqual(try store.load(), draft)

        try store.clear()
        XCTAssertNil(try store.load())
    }

    func testCorruptDraftIsIgnoredWithoutDeletingOtherData() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipmanQuickClipDraftTests-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("quick-clip-draft.json")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)

        let store = ClipDraftStore(fileURL: url)
        XCTAssertThrowsError(try store.load())
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor
    func testBackgroundingPersistsAndRestoresAnEntryEditDraft() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipmanEntryEditDraftTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let quickStore = ClipDraftStore(fileURL: root.appendingPathComponent("quick.json"))
        let editStore = ClipDraftStore(fileURL: root.appendingPathComponent("edit.json"))
        let original = ClipEntry(Id: "existing-entry", Text: "Original text")
        let edited = ClipEntry(Id: "existing-entry", Text: "Unsaved revised text", Name: "Draft name")

        let model = ClipmanAppModel(
            settings: ClipmanSettings.empty,
            quickClipDraftStore: quickStore,
            entryEditDraftStore: editStore
        )
        model.beginEditing(original)
        model.updateEntryEditDraft(edited)
        model.sceneMovedToBackground()

        let restored = ClipmanAppModel(
            settings: ClipmanSettings.empty,
            quickClipDraftStore: quickStore,
            entryEditDraftStore: editStore
        )
        XCTAssertEqual(restored.entryEditDraft, edited)
    }

    @MainActor
    func testCancellingAnEntryEditClearsItsPersistedDraft() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipmanEntryEditDraftTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let quickStore = ClipDraftStore(fileURL: root.appendingPathComponent("quick.json"))
        let editStore = ClipDraftStore(fileURL: root.appendingPathComponent("edit.json"))
        let draft = ClipEntry(Id: "existing-entry", Text: "Unsaved text")
        try editStore.save(draft)

        let model = ClipmanAppModel(
            settings: ClipmanSettings.empty,
            quickClipDraftStore: quickStore,
            entryEditDraftStore: editStore
        )
        model.discardEntryEditDraft()

        XCTAssertNil(model.entryEditDraft)
        XCTAssertNil(try editStore.load())
    }

    @MainActor
    func testUnlockRestoresTheExistingEntryEditor() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipmanEntryEditDraftTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let quickStore = ClipDraftStore(fileURL: root.appendingPathComponent("quick.json"))
        let editStore = ClipDraftStore(fileURL: root.appendingPathComponent("edit.json"))
        let draft = ClipEntry(Id: "existing-entry", Text: "Unsaved text")
        try editStore.save(draft)
        let repository = DraftRestoreRepository(database: ClipDatabase(Entries: [draft]))
        let model = ClipmanAppModel(
            settings: ClipmanSettings.empty,
            historyRepository: repository,
            quickClipDraftStore: quickStore,
            entryEditDraftStore: editStore
        )

        model.sceneBecameActive()
        for _ in 0..<100 where !model.showingEntryEdit {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertTrue(model.isUnlocked)
        XCTAssertTrue(model.showingEntryEdit)
        XCTAssertEqual(model.entryEditDraft, draft)
        model.sceneMovedToBackground()
    }
}

private actor DraftRestoreRepository: MobileHistoryRepositoryProtocol {
    private let database: ClipDatabase

    init(database: ClipDatabase) {
        self.database = database
    }

    func loadLocal(password: String) async throws -> ClipDatabase? { database }

    func saveLocal(
        _ database: ClipDatabase,
        password: String,
        backupSettings: ClipmanSettings?
    ) async throws -> String? { nil }

    func synchronize(
        settings: ClipmanSettings,
        current: ClipDatabase,
        localAlreadySaved: Bool
    ) async throws -> MobileSyncResult {
        MobileSyncResult(database: current, revision: "", uploaded: false, backupError: nil)
    }

    func persistMutation(
        settings: ClipmanSettings,
        current: ClipDatabase,
        expectedRevision: String
    ) async throws -> MobileSyncResult {
        MobileSyncResult(database: current, revision: "", uploaded: false, backupError: nil)
    }
}
