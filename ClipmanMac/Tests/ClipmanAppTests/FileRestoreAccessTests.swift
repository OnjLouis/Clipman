import Foundation
import Darwin
import XCTest
@testable import Clipman

final class FileRestoreAccessTests: XCTestCase {
    func testDuplicatePathsAreRestoredOnceInFirstSeenOrder() throws {
        try withFixture { root in
            let first = root.appendingPathComponent("first.txt")
            let second = root.appendingPathComponent("second.txt")
            try Data("first".utf8).write(to: first)
            try Data("second".utf8).write(to: second)
            XCTAssertEqual(try FileRestoreAccess.readablePaths([first.path, second.path, first.path, second.path]), [first.path, second.path])
        }
    }

    func testReadableFilesAndFoldersAreNotModified() throws {
        try withFixture { root in
            let file = root.appendingPathComponent("Owner's file.pkg")
            let data = Data("Unchanged fixture".utf8)
            try data.write(to: file)
            XCTAssertEqual(try FileRestoreAccess.readablePaths([file.path, root.path]), [file.path, root.path])
            XCTAssertEqual(try Data(contentsOf: file), data)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [file.lastPathComponent])
        }
    }

    func testMissingFilesAreSkippedWithoutDiscardingReadableFiles() throws {
        try withFixture { root in
            let missing = root.appendingPathComponent("missing.pkg").path
            XCTAssertEqual(try FileRestoreAccess.readablePaths([missing, root.path]), [root.path])
            XCTAssertEqual(try FileRestoreAccess.readablePaths([missing]), [])
        }
    }

    func testEmptyFilesAndSpecialFilesDoNotBlockRestoration() throws {
        try withFixture { root in
            let empty = root.appendingPathComponent("empty.txt")
            try Data().write(to: empty)
            let pipe = root.appendingPathComponent("pipe")
            XCTAssertEqual(Darwin.mkfifo(pipe.path, 0o600), 0)
            XCTAssertEqual(try FileRestoreAccess.readablePaths([empty.path, pipe.path]), [empty.path, pipe.path])
            XCTAssertEqual(try Data(contentsOf: empty), Data())
        }
    }

    func testUnreadableFilesFailWithoutChangingPermissionsOrContents() throws {
        try withFixture { root in
            let file = root.appendingPathComponent("unreadable.pkg")
            let data = Data("Preserved content".utf8)
            try data.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
            XCTAssertThrowsError(try FileRestoreAccess.readablePaths([file.path]))
            let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(permissions?.intValue, 0)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            XCTAssertEqual(try Data(contentsOf: file), data)
        }
    }

    private func withFixture(_ body: (URL) throws -> Void) throws {
        let parent = ProcessInfo.processInfo.environment["CLIPMAN_TEST_TEMP"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let root = parent.appendingPathComponent("ClipmanFileAccess-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
}
