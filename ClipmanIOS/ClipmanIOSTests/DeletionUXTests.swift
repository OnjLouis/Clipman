import XCTest
@testable import Clipman

final class DeletionUXTests: XCTestCase {
    @MainActor
    func testDeleteRemovesOnlyTheTargetBeforePersistenceCompletes() async throws {
        let repository = DeletionTestRepository(saveBehavior: .waitForRelease)
        let model = ClipmanAppModel(
            settings: testSettings(storageMode: .local),
            historyRepository: repository
        )
        let first = ClipEntry(Id: "first", Text: "First", ManualOrder: 1)
        let second = ClipEntry(Id: "second", Text: "Second", ManualOrder: 2)
        model.database = ClipDatabase(Entries: [first, second])

        let task = try XCTUnwrap(model.delete(first))

        XCTAssertEqual(model.database.Entries.map(\.Id), ["second"])
        XCTAssertEqual(model.database.Entries.map(\.ManualOrder), [1])
        XCTAssertEqual(model.database.DeletedEntries.count, 1)
        XCTAssertEqual(model.database.DeletedEntries[0].Id, "first")
        XCTAssertEqual(model.database.DeletedEntries[0].TextHash, SyncConflictResolver.textHash("First"))
        XCTAssertEqual(model.status, "Entry deleted.")
        await repository.waitUntilSaveStarts()
        XCTAssertEqual(model.database.Entries.map(\.Id), ["second"])

        await repository.releaseSave()
        await task.value
        XCTAssertEqual(model.database.Entries.map(\.Id), ["second"])
    }

    @MainActor
    func testLocalPersistenceFailureRestoresTheExactPreviousDatabase() async throws {
        let repository = DeletionTestRepository(saveBehavior: .fail)
        let model = ClipmanAppModel(
            settings: testSettings(storageMode: .local),
            historyRepository: repository
        )
        let first = ClipEntry(Id: "first", Text: "First", ManualOrder: 1)
        let second = ClipEntry(Id: "second", Text: "Second", ManualOrder: 2)
        let original = ClipDatabase(Entries: [first, second])
        model.database = original

        let task = try XCTUnwrap(model.delete(first))
        await task.value

        XCTAssertTrue(SyncConflictResolver.hasSameContent(model.database, original))
        XCTAssertEqual(model.status, "Delete failed. Entry restored.")
    }

    @MainActor
    func testServerFailureKeepsTheDurableLocalDeletionPendingForRetry() async throws {
        let repository = DeletionTestRepository(
            saveBehavior: .succeed,
            synchronizeBehavior: .fail
        )
        let model = ClipmanAppModel(
            settings: testSettings(storageMode: .server),
            historyRepository: repository
        )
        let entry = ClipEntry(Id: "target", Text: "Target", ManualOrder: 1)
        model.database = ClipDatabase(Entries: [entry])

        let task = try XCTUnwrap(model.delete(entry))
        await task.value

        XCTAssertTrue(model.database.Entries.isEmpty)
        XCTAssertEqual(model.status, "Entry deleted locally. Server sync will retry.")
    }

    func testFocusMovesForwardThenBackwardAndHandlesGroupedLinkRows() {
        XCTAssertEqual(
            HistoryDeletionFocusResolver.nextID(afterRemoving: ["b"], from: ["a", "b", "c"]),
            "c"
        )
        XCTAssertEqual(
            HistoryDeletionFocusResolver.nextID(afterRemoving: ["c"], from: ["a", "b", "c"]),
            "b"
        )
        XCTAssertEqual(
            HistoryDeletionFocusResolver.nextID(
                afterRemoving: ["entry-1-link-0", "entry-1-link-1"],
                from: ["before", "entry-1-link-0", "entry-1-link-1", "after"]
            ),
            "after"
        )
        XCTAssertNil(
            HistoryDeletionFocusResolver.nextID(afterRemoving: ["only"], from: ["only"])
        )
    }

    func testOptimisticDeletionKeepsExistingArrayOrderWithoutNormalizing() throws {
        let first = ClipEntry(Id: "first", Text: "First", ManualOrder: 30)
        let target = ClipEntry(Id: "target", Text: "Target", ManualOrder: 10)
        let last = ClipEntry(Id: "last", Text: "Last", ManualOrder: 20)
        let deletion = try XCTUnwrap(OptimisticEntryDeletion(
            database: ClipDatabase(Entries: [first, target, last]),
            entryID: target.Id,
            machineName: "iPhone"
        ))

        XCTAssertEqual(deletion.optimisticDatabase.Entries.map(\.Id), ["first", "last"])
        XCTAssertEqual(deletion.optimisticDatabase.Entries.map(\.ManualOrder), [1, 2])
    }

    @MainActor
    private func testSettings(storageMode: MobileStorageMode) -> ClipmanSettings {
        var settings = ClipmanSettings.empty
        settings.storageMode = storageMode
        settings.historyPassword = "test-password"
        return settings
    }
}

private enum DeletionTestError: Error {
    case expectedFailure
}

private actor DeletionTestRepository: MobileHistoryRepositoryProtocol {
    enum SaveBehavior { case succeed, fail, waitForRelease }
    enum SynchronizeBehavior: Equatable { case succeed, fail }

    private let saveBehavior: SaveBehavior
    private let synchronizeBehavior: SynchronizeBehavior
    private var saveStarted = false
    private var saveStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var saveRelease: CheckedContinuation<Void, Never>?

    init(
        saveBehavior: SaveBehavior,
        synchronizeBehavior: SynchronizeBehavior = .succeed
    ) {
        self.saveBehavior = saveBehavior
        self.synchronizeBehavior = synchronizeBehavior
    }

    func loadLocal(password: String) async throws -> ClipDatabase? { nil }

    func saveLocal(
        _ database: ClipDatabase,
        password: String,
        backupSettings: ClipmanSettings?
    ) async throws -> String? {
        saveStarted = true
        saveStartWaiters.forEach { $0.resume() }
        saveStartWaiters.removeAll()
        switch saveBehavior {
        case .succeed:
            return nil
        case .fail:
            throw DeletionTestError.expectedFailure
        case .waitForRelease:
            await withCheckedContinuation { saveRelease = $0 }
            return nil
        }
    }

    func synchronize(
        settings: ClipmanSettings,
        current: ClipDatabase,
        localAlreadySaved: Bool
    ) async throws -> MobileSyncResult {
        if synchronizeBehavior == .fail { throw DeletionTestError.expectedFailure }
        return MobileSyncResult(database: current, revision: "test", uploaded: true, backupError: nil)
    }

    func waitUntilSaveStarts() async {
        if saveStarted { return }
        await withCheckedContinuation { saveStartWaiters.append($0) }
    }

    func releaseSave() {
        saveRelease?.resume()
        saveRelease = nil
    }
}
