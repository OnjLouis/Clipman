import XCTest
@testable import Clipman

final class SettingsMigrationTests: XCTestCase {
    @MainActor
    func testExistingBackupFolderSeedsSharedFolder() {
        var settings = ClipmanSettings.empty
        settings.cloudBackupBookmark = Data([1, 2, 3])
        settings.cloudBackupFolderName = "Clipman Backup"

        settings.reuseBackupFolderForSharedSyncIfNeeded()

        XCTAssertEqual(settings.sharedFolderBookmark, settings.cloudBackupBookmark)
        XCTAssertEqual(settings.sharedFolderName, "Clipman Backup")
    }

    @MainActor
    func testExplicitSharedFolderIsNotReplacedByBackupFolder() {
        var settings = ClipmanSettings.empty
        settings.cloudBackupBookmark = Data([1, 2, 3])
        settings.cloudBackupFolderName = "Clipman Backup"
        settings.sharedFolderBookmark = Data([4, 5, 6])
        settings.sharedFolderName = "Clipman Sync"

        settings.reuseBackupFolderForSharedSyncIfNeeded()

        XCTAssertEqual(settings.sharedFolderBookmark, Data([4, 5, 6]))
        XCTAssertEqual(settings.sharedFolderName, "Clipman Sync")
    }
}
