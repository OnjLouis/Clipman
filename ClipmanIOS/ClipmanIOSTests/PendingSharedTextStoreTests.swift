import Foundation
import XCTest
@testable import Clipman

final class PendingSharedTextStoreTests: XCTestCase {
    func testPendingTextAndHTMLRoundTrip() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PendingSharedTextStore(rootURL: root.appendingPathComponent("queue"))

        let queued = try store.enqueue(
            text: "Example page",
            html: "<p><strong>Example</strong> page</p>"
        )
        XCTAssertEqual(queued.text, "Example page")
        XCTAssertEqual(queued.html, "<p><strong>Example</strong> page</p>")
        XCTAssertEqual(try store.pendingItems(), [queued])

        try store.remove(queued)
        XCTAssertTrue(try store.pendingItems().isEmpty)
    }

    func testStandaloneURLRemainsUnchanged() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PendingSharedTextStore(rootURL: root.appendingPathComponent("queue"))
        let url = "https://www.youtube.com/watch?v=example"

        let queued = try store.enqueue(text: url)

        XCTAssertEqual(queued.text, url)
        XCTAssertEqual(queued.html, "")
    }

    func testPendingTextQueueIsBounded() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PendingSharedTextStore(rootURL: root.appendingPathComponent("queue"))

        for index in 0..<PendingSharedTextStore.maximumPendingItems {
            _ = try store.enqueue(text: "Shared item \(index)")
        }
        XCTAssertThrowsError(try store.enqueue(text: "One item too many")) { error in
            XCTAssertEqual(error as? PendingSharedTextError, .queueFull)
        }
    }

    func testEmptyAndOversizedTextAreRejectedWithoutQueueArtifacts() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = root.appendingPathComponent("queue")
        let store = try PendingSharedTextStore(rootURL: queue)

        XCTAssertThrowsError(try store.enqueue(text: "   \n")) { error in
            XCTAssertEqual(error as? PendingSharedTextError, .emptyText)
        }
        let oversized = String(repeating: "a", count: PendingSharedTextStore.maximumTextBytes + 1)
        XCTAssertThrowsError(try store.enqueue(text: oversized)) { error in
            XCTAssertEqual(error as? PendingSharedTextError, .textTooLarge)
        }
        XCTAssertTrue(try store.pendingItems().isEmpty)
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipmanPendingTextShareTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
