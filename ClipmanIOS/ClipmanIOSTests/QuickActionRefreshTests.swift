import XCTest
@testable import Clipman

final class QuickActionRefreshTests: XCTestCase {
    @MainActor
    func testCopyLatestRefreshesSynchronizedHistoryBeforeSelectingAnEntry() async {
        var settings = ClipmanSettings.empty
        settings.storageMode = .server
        settings.serverURL = "https://example.test"
        settings.serverToken = "test-token"
        settings.historyPassword = "test-password"

        let cached = ClipEntry(Id: "cached", Text: "Cached entry", CreatedUnixMs: 100)
        let remote = ClipEntry(Id: "remote", Text: "Current server entry", CreatedUnixMs: 200)
        let repository = QuickActionRefreshRepository(
            behavior: .success(ClipDatabase(Entries: [cached, remote]))
        )
        let model = ClipmanAppModel(settings: settings, historyRepository: repository)
        model.database = ClipDatabase(Entries: [cached])

        let latest = await model.latestEntryForQuickAction()
        let synchronizeCount = await repository.synchronizeCount()

        XCTAssertEqual(latest?.Id, remote.Id)
        XCTAssertEqual(synchronizeCount, 1)
    }

    @MainActor
    func testCopyLatestDoesNotUseCachedHistoryWhenRefreshFails() async {
        var settings = ClipmanSettings.empty
        settings.storageMode = .server
        settings.serverURL = "https://example.test"
        settings.serverToken = "test-token"
        settings.historyPassword = "test-password"

        let cached = ClipEntry(Id: "cached", Text: "Cached entry", CreatedUnixMs: 100)
        let repository = QuickActionRefreshRepository(
            local: ClipDatabase(Entries: [cached]),
            behavior: .failure
        )
        let model = ClipmanAppModel(settings: settings, historyRepository: repository)
        model.database = ClipDatabase(Entries: [cached])

        let latest = await model.latestEntryForQuickAction()

        XCTAssertNil(latest)
        XCTAssertEqual(model.database.Entries.map(\.Id), [cached.Id])
    }
}

private enum QuickActionRefreshError: Error {
    case unavailable
}

private enum QuickActionRefreshBehavior: Sendable {
    case success(ClipDatabase)
    case failure
}

private actor QuickActionRefreshRepository: MobileHistoryRepositoryProtocol {
    private let behavior: QuickActionRefreshBehavior
    private let local: ClipDatabase?
    private var syncCount = 0

    init(local: ClipDatabase? = nil, behavior: QuickActionRefreshBehavior) {
        self.local = local
        self.behavior = behavior
    }

    func loadLocal(password: String) async throws -> ClipDatabase? { local }

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
        syncCount += 1
        let database: ClipDatabase
        switch behavior {
        case .success(let result):
            database = result
        case .failure:
            throw QuickActionRefreshError.unavailable
        }
        return MobileSyncResult(
            database: database,
            revision: "current-revision",
            uploaded: false,
            backupError: nil
        )
    }

    func persistMutation(
        settings: ClipmanSettings,
        current: ClipDatabase,
        expectedRevision: String
    ) async throws -> MobileSyncResult {
        try await synchronize(settings: settings, current: current, localAlreadySaved: true)
    }

    func synchronizeCount() -> Int { syncCount }
}
