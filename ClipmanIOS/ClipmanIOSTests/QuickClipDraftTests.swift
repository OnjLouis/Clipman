import XCTest
@testable import Clipman

final class QuickClipDraftTests: XCTestCase {
    @MainActor
    func testBackgroundingPersistsAndRestoresTheActiveDraft() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipmanQuickClipDraftTests-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("quick-clip-draft.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = QuickClipDraftStore(fileURL: url)
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

        let store = QuickClipDraftStore(fileURL: url)
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

        let store = QuickClipDraftStore(fileURL: url)
        XCTAssertThrowsError(try store.load())
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}
