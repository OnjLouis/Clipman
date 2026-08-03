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
        XCTAssertEqual(model.status, "Deleting entry.")
        await repository.waitUntilSaveStarts()
        XCTAssertEqual(model.database.Entries.map(\.Id), ["second"])

        await repository.releaseSave()
        await task.value
        XCTAssertEqual(model.database.Entries.map(\.Id), ["second"])
        XCTAssertEqual(model.status, "Entry deleted.")
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

    @MainActor
    func testServerSuccessIsNotReportedUntilSynchronizationCompletes() async throws {
        let repository = DeletionTestRepository(
            saveBehavior: .succeed,
            synchronizeBehavior: .waitForRelease
        )
        let model = ClipmanAppModel(
            settings: testSettings(storageMode: .server),
            historyRepository: repository
        )
        let entry = ClipEntry(Id: "target", Text: "Target", ManualOrder: 1)
        model.database = ClipDatabase(Entries: [entry])

        let task = try XCTUnwrap(model.delete(entry))
        await repository.waitUntilSynchronizeStarts()

        XCTAssertEqual(model.status, "Deleting entry; server sync in progress.")
        await repository.releaseSynchronize()
        await task.value
        XCTAssertEqual(model.status, "Entry deleted and synced with Clipman Server.")
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

    func testMergeAppliesDeletionByID() {
        let entry = ClipEntry(
            Id: "deleted-id",
            Text: "Deleted by ID",
            CreatedUnixMs: 1_000,
            LastUsedUnixMs: 1_000
        )
        let marker = DeletedClipEntry(
            Id: entry.Id,
            TextHash: "",
            DeletedUnixMs: TimeUtil.nowUnixMs(),
            SourceMachine: "Mac"
        )

        let merged = SyncConflictResolver.merge(
            target: ClipDatabase(DeletedEntries: [marker]),
            source: ClipDatabase(Entries: [entry])
        )

        XCTAssertTrue(merged.Entries.isEmpty)
    }

    func testMergeAppliesRecentDeletionByTextHash() {
        let now = TimeUtil.nowUnixMs()
        let entry = ClipEntry(
            Id: "old-copy",
            Text: "Deleted text",
            CreatedUnixMs: now - 2_000,
            LastUsedUnixMs: now - 1_000
        )
        let marker = DeletedClipEntry(
            Id: "different-id",
            TextHash: SyncConflictResolver.textHash(entry.Text),
            DeletedUnixMs: now,
            SourceMachine: "Mac"
        )

        let merged = SyncConflictResolver.merge(
            target: ClipDatabase(DeletedEntries: [marker]),
            source: ClipDatabase(Entries: [entry])
        )

        XCTAssertTrue(merged.Entries.isEmpty)
    }

    func testMergeKeepsTextRecreatedAfterDeletion() {
        let now = TimeUtil.nowUnixMs()
        let entry = ClipEntry(
            Id: "new-copy",
            Text: "Recreated text",
            CreatedUnixMs: now,
            LastUsedUnixMs: now
        )
        let marker = DeletedClipEntry(
            Id: "old-copy",
            TextHash: SyncConflictResolver.textHash(entry.Text),
            DeletedUnixMs: now - 1_000,
            SourceMachine: "Mac"
        )

        let merged = SyncConflictResolver.merge(
            target: ClipDatabase(DeletedEntries: [marker]),
            source: ClipDatabase(Entries: [entry])
        )

        XCTAssertEqual(merged.Entries.map(\.Id), [entry.Id])
    }

    func testMergePrunesExpiredDeletionMarkers() {
        let old = TimeUtil.nowUnixMs() - Int64(91 * 24 * 60 * 60 * 1_000)
        let entry = ClipEntry(
            Id: "returned-id",
            Text: "Returned text",
            CreatedUnixMs: old - 1_000,
            LastUsedUnixMs: old - 1_000
        )
        let marker = DeletedClipEntry(
            Id: entry.Id,
            TextHash: SyncConflictResolver.textHash(entry.Text),
            DeletedUnixMs: old,
            SourceMachine: "Mac"
        )

        let merged = SyncConflictResolver.merge(
            target: ClipDatabase(DeletedEntries: [marker]),
            source: ClipDatabase(Entries: [entry])
        )

        XCTAssertEqual(merged.Entries.map(\.Id), [entry.Id])
        XCTAssertTrue(merged.DeletedEntries.isEmpty)
    }

    func testLargeMergePreservesLiveEntriesAndRecentDeletions() {
        let now = TimeUtil.nowUnixMs()
        let entries = (0..<400).map { index in
            ClipEntry(
                Id: "entry-\(index)",
                Text: "Text \(index)",
                CreatedUnixMs: now - 10_000,
                LastUsedUnixMs: now - 10_000,
                ManualOrder: Int64(index + 1)
            )
        }
        let markers = (0..<200).map { index in
            DeletedClipEntry(
                Id: "marker-\(index)",
                TextHash: SyncConflictResolver.textHash("Text \(index)"),
                DeletedUnixMs: now,
                SourceMachine: "Mac"
            )
        }

        let merged = SyncConflictResolver.merge(
            target: ClipDatabase(DeletedEntries: markers),
            source: ClipDatabase(Entries: entries)
        )

        XCTAssertEqual(merged.Entries.count, 200)
        XCTAssertEqual(merged.Entries.first?.Text, "Text 200")
        XCTAssertEqual(merged.Entries.last?.Text, "Text 399")
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
    enum SynchronizeBehavior: Equatable { case succeed, fail, waitForRelease }

    private let saveBehavior: SaveBehavior
    private let synchronizeBehavior: SynchronizeBehavior
    private var saveStarted = false
    private var saveStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var saveRelease: CheckedContinuation<Void, Never>?
    private var synchronizeStarted = false
    private var synchronizeStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var synchronizeRelease: CheckedContinuation<Void, Never>?

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
        synchronizeStarted = true
        synchronizeStartWaiters.forEach { $0.resume() }
        synchronizeStartWaiters.removeAll()
        if synchronizeBehavior == .fail { throw DeletionTestError.expectedFailure }
        if synchronizeBehavior == .waitForRelease {
            await withCheckedContinuation { synchronizeRelease = $0 }
        }
        return MobileSyncResult(database: current, revision: "test", uploaded: true, backupError: nil)
    }

    func persistMutation(
        settings: ClipmanSettings,
        current: ClipDatabase,
        expectedRevision: String
    ) async throws -> MobileSyncResult {
        do {
            _ = try await saveLocal(
                current,
                password: settings.historyPassword,
                backupSettings: settings
            )
        } catch {
            throw MobileMutationError(localSaved: false, message: error.localizedDescription)
        }
        do {
            return try await synchronize(
                settings: settings,
                current: current,
                localAlreadySaved: true
            )
        } catch {
            throw MobileMutationError(localSaved: true, message: error.localizedDescription)
        }
    }

    func waitUntilSaveStarts() async {
        if saveStarted { return }
        await withCheckedContinuation { saveStartWaiters.append($0) }
    }

    func releaseSave() {
        saveRelease?.resume()
        saveRelease = nil
    }

    func waitUntilSynchronizeStarts() async {
        if synchronizeStarted { return }
        await withCheckedContinuation { synchronizeStartWaiters.append($0) }
    }

    func releaseSynchronize() {
        synchronizeRelease?.resume()
        synchronizeRelease = nil
    }
}
