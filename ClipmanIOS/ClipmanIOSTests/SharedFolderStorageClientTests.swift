import XCTest
@testable import Clipman

final class SharedFolderStorageClientTests: XCTestCase {
    private let password = "shared-folder-test-password"

    func testCreateDownloadAndConditionalUpdate() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = SharedFolderStorageClient(directory: directory, password: password)
        let first = try encodedDatabase(text: "First")

        let firstRevision = try await client.upload(data: first, expectedRevision: "", createOnly: true)
        let download = try await client.download()

        XCTAssertEqual(download.revision, firstRevision)
        XCTAssertEqual(try ClipDatabaseFile.load(download.data, password: password).Entries.map(\.Text), ["First"])

        let second = try encodedDatabase(text: "Second")
        let secondRevision = try await client.upload(
            data: second,
            expectedRevision: firstRevision,
            createOnly: false
        )
        XCTAssertNotEqual(secondRevision, firstRevision)
        let secondDownload = try await client.download()
        XCTAssertEqual(try ClipDatabaseFile.load(secondDownload.data, password: password).Entries.map(\.Text), ["Second"])
    }

    func testStaleRevisionCannotOverwriteNewerFile() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = SharedFolderStorageClient(directory: directory, password: password)
        let originalRevision = try await client.upload(
            data: try encodedDatabase(text: "Original"),
            expectedRevision: "",
            createOnly: true
        )
        let external = try encodedDatabase(text: "External")
        try external.write(to: directory.appendingPathComponent("clipman-history.clipdb"), options: .atomic)

        do {
            _ = try await client.upload(
                data: try encodedDatabase(text: "Stale local"),
                expectedRevision: originalRevision,
                createOnly: false
            )
            XCTFail("A stale revision must not overwrite a newer shared file.")
        } catch ServerStorageError.conflict {
            let stored = try await client.download()
            XCTAssertEqual(try ClipDatabaseFile.load(stored.data, password: password).Entries.map(\.Text), ["External"])
        }
    }

    func testUnreadableExistingHistoryIsNotTreatedAsMissing() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("clipman-history.clipdb", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let client = SharedFolderStorageClient(directory: directory, password: password)

        do {
            _ = try await client.download()
            XCTFail("An unreadable existing history must not be reported as missing.")
        } catch ServerStorageError.notFound {
            XCTFail("An unreadable existing history must not be reported as missing.")
        } catch {
            // Expected: callers retain their local cache and retry after hydration.
        }

        do {
            _ = try await client.upload(
                data: try encodedDatabase(text: "Must not replace"),
                expectedRevision: "",
                createOnly: true
            )
            XCTFail("An unreadable existing history must not be replaced.")
        } catch {
            XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        }
    }

    func testConflictSiblingIsMergedBeforeReplacement() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let canonical = directory.appendingPathComponent("clipman-history.clipdb")
        let conflict = directory.appendingPathComponent("clipman-history (Other conflicted copy).clipdb")
        try encodedDatabase(id: "one", text: "From iPhone").write(to: canonical)
        try encodedDatabase(id: "two", text: "From Mac").write(to: conflict)
        let client = SharedFolderStorageClient(directory: directory, password: password)

        let download = try await client.download()
        let merged = try ClipDatabaseFile.load(download.data, password: password)
        XCTAssertEqual(Set(merged.Entries.map(\.Text)), Set(["From iPhone", "From Mac"]))

        _ = try await client.upload(
            data: download.data,
            expectedRevision: download.revision,
            createOnly: false
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: conflict.path))
        let persisted = try ClipDatabaseFile.load(Data(contentsOf: canonical), password: password)
        XCTAssertEqual(Set(persisted.Entries.map(\.Text)), Set(["From iPhone", "From Mac"]))
    }

    func testConflictSiblingDeletionDoesNotResurrectAnEntry() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let canonical = directory.appendingPathComponent("clipman-history.clipdb")
        let conflict = directory.appendingPathComponent("clipman-history (iPad conflicted copy).clipdb")
        let now = TimeUtil.nowUnixMs()
        let entry = ClipEntry(
            Id: "deleted-entry",
            Text: "Delete me",
            SourceMachine: "Mac",
            CreatedUnixMs: now - 100,
            LastUsedUnixMs: now - 100,
            ModifiedUnixMs: now - 100
        )
        try ClipDatabaseFile.save(ClipDatabase(Entries: [entry]), password: password).write(to: canonical)
        let deleted = DeletedClipEntry(
            Id: entry.Id,
            TextHash: SyncConflictResolver.textHash(entry.Text),
            DeletedUnixMs: now,
            SourceMachine: "iPhone"
        )
        try ClipDatabaseFile.save(ClipDatabase(DeletedEntries: [deleted]), password: password).write(to: conflict)

        let client = SharedFolderStorageClient(directory: directory, password: password)
        let download = try await client.download()
        let merged = try ClipDatabaseFile.load(download.data, password: password)
        XCTAssertTrue(merged.Entries.isEmpty)
        XCTAssertEqual(merged.DeletedEntries.map(\.Id), [entry.Id])
    }

    func testChannelUsesMacCompatibleFilename() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = SharedFolderStorageClient(directory: directory, password: password)
        let channel = try XCTUnwrap(client.historyChannel("desktop only", password: password))
        XCTAssertEqual(channel.databaseID, "clipman-channel-desktop-only.clipdb")
        XCTAssertEqual(client.historySyncRules(password: password)?.databaseID, "clipman-sync-rules.clipdb")
    }

    private func encodedDatabase(id: String = UUID().uuidString, text: String) throws -> Data {
        try ClipDatabaseFile.save(
            ClipDatabase(Entries: [ClipEntry(
                Id: id,
                Text: text,
                SourceMachine: "Test device",
                CreatedUnixMs: 1,
                LastUsedUnixMs: 1,
                ModifiedUnixMs: 1
            )]),
            password: password
        )
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipmanSharedFolderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
