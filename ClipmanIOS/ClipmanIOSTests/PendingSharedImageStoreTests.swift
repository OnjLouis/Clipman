import Foundation
import XCTest
@testable import Clipman

final class PendingSharedImageStoreTests: XCTestCase {
    func testPendingPhotoRoundTripsAtomically() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.jpg")
        try Data([1, 2, 3, 4]).write(to: source)
        let store = try PendingSharedImageStore(rootURL: root.appendingPathComponent("queue"))

        let queued = try store.enqueue(sourceURL: source, suggestedFilename: "Camera/holiday.jpg")
        XCTAssertEqual(queued.suggestedFilename, "holiday.jpg")
        XCTAssertEqual(try store.readBounded(queued), Data([1, 2, 3, 4]))
        XCTAssertEqual(try store.pendingItems(), [queued])

        try store.remove(queued)
        XCTAssertTrue(try store.pendingItems().isEmpty)
    }

    func testPendingQueueIsBounded() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.png")
        try Data([1]).write(to: source)
        let store = try PendingSharedImageStore(rootURL: root.appendingPathComponent("queue"))

        for index in 0..<PendingSharedImageStore.maximumPendingItems {
            _ = try store.enqueue(sourceURL: source, suggestedFilename: "photo-\(index).png")
        }
        XCTAssertThrowsError(try store.enqueue(sourceURL: source, suggestedFilename: "extra.png")) { error in
            XCTAssertEqual(error as? PendingSharedImageError, .queueFull)
        }
    }

    func testOversizedPhotoIsRejectedWithoutLeavingQueueArtifacts() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("large.jpg")
        FileManager.default.createFile(atPath: source.path, contents: Data([1]))
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: UInt64(PendingSharedImageStore.maximumInputBytes + 1))
        try handle.close()
        let queue = root.appendingPathComponent("queue")
        let store = try PendingSharedImageStore(rootURL: queue)

        XCTAssertThrowsError(try store.enqueue(sourceURL: source, suggestedFilename: "large.jpg")) { error in
            XCTAssertEqual(error as? PendingSharedImageError, .imageTooLarge)
        }
        XCTAssertTrue(try store.pendingItems().isEmpty)
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipmanPendingShareTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
