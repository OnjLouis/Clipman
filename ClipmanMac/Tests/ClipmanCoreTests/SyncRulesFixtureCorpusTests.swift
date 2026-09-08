import XCTest
@testable import ClipmanCore

/// Task 6.1 of the sync rules plan: decode the interoperability blobs the Go
/// reference implementation generated under
/// `ClipmanCli/testdata/fixtures/go/`, apply this client's own subscription
/// and merge logic for device Jeff-iPhone (subscribed to the work channel
/// only), and compare the assembled view against `expected-view.json`. A
/// failure here is a real cross-device sync break, not a style disagreement.
final class SyncRulesFixtureCorpusTests: XCTestCase {
    private let password = "example-password"

    /// The reduced expectation shape recorded in the corpus
    /// (ClipmanCli/testdata/fixtures/README.md).
    private struct FixtureViewEntry: Decodable {
        var id: String
        var text: String
        var name: String
        var group: String
        var sourceMachine: String
        var createdUnixMs: Int64
        var lastUsedUnixMs: Int64
        var pinned: Bool
        var isTemplate: Bool
        var manualOrder: Int64
        var hasRichText: Bool
    }

    private struct FixtureExpectedView: Decodable {
        var version: Int
        var updatedUnixMs: Int64
        var entries: [FixtureViewEntry]
        var deleted: [FixtureDeleted]
    }

    private struct FixtureDeleted: Decodable {
        var id: String
    }

    /// The corpus lives in the sibling ClipmanCli tree; this test file's own
    /// path anchors the lookup so `swift test` works from any checkout
    /// location.
    private func corpusDirectory() throws -> URL {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ClipmanCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // ClipmanMac
            .deletingLastPathComponent()  // repository root
        let directory = repoRoot
            .appendingPathComponent("ClipmanCli")
            .appendingPathComponent("testdata")
            .appendingPathComponent("fixtures")
            .appendingPathComponent("go")
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw XCTSkip("the go-reference sync rules fixture corpus is not present")
        }
        return directory
    }

    func testGoSyncRulesFixtureCorpusDecodesIntoTheExpectedView() throws {
        let directory = try corpusDirectory()

        let rulesPayload = try XCTUnwrap(
            ClipDatabaseFile.loadRawPayload(directory.appendingPathComponent("sync-rules.clipdb"), password: password)
        )
        let document = try XCTUnwrap(SyncRuleEngine.parse(rulesPayload))
        XCTAssertTrue(document.Enabled)
        XCTAssertNil(SyncRuleEngine.validate(document))
        XCTAssertEqual(SyncRuleEngine.subscribedChannels(document: document, deviceName: "Jeff-iPhone"), ["work"])

        let core = try ClipDatabaseFile.load(directory.appendingPathComponent("core.clipdb"), password: password)
        let work = try ClipDatabaseFile.load(directory.appendingPathComponent("channel-work.clipdb"), password: password)
        let images = try ClipDatabaseFile.load(directory.appendingPathComponent("channel-images.clipdb"), password: password)
        XCTAssertFalse(core.Entries.isEmpty)
        XCTAssertFalse(work.Entries.isEmpty)
        XCTAssertFalse(images.Entries.isEmpty)

        // Assemble the subscribed view exactly as the client does: core first,
        // then the subscribed channels in document order, then the dense
        // manual-order renumbering of the merged database.
        var view = ClipDatabase()
        SyncConflictResolver.merge(into: &view, source: core)
        SyncConflictResolver.merge(into: &view, source: work)
        SyncConflictResolver.normalize(&view)

        let expectedData = try Data(contentsOf: directory.appendingPathComponent("expected-view.json"))
        let expected = try JSONDecoder().decode(FixtureExpectedView.self, from: expectedData)

        let actual = view.Entries.sorted { $0.Id < $1.Id }
        XCTAssertEqual(actual.count, expected.entries.count, "view entry count")
        for (got, want) in zip(actual, expected.entries) {
            XCTAssertEqual(got.Id, want.id)
            XCTAssertEqual(got.Text, want.text, "entry \(want.id) text")
            XCTAssertEqual(got.Name, want.name, "entry \(want.id) name")
            XCTAssertEqual(got.Group, want.group, "entry \(want.id) group")
            XCTAssertEqual(got.SourceMachine, want.sourceMachine, "entry \(want.id) source device")
            XCTAssertEqual(got.CreatedUnixMs, want.createdUnixMs, "entry \(want.id) created")
            XCTAssertEqual(got.LastUsedUnixMs, want.lastUsedUnixMs, "entry \(want.id) last used")
            XCTAssertEqual(got.Pinned, want.pinned, "entry \(want.id) pinned")
            XCTAssertEqual(got.IsTemplate, want.isTemplate, "entry \(want.id) template")
            XCTAssertEqual(got.ManualOrder, want.manualOrder, "entry \(want.id) manual order")
            XCTAssertEqual(got.RichText != nil, want.hasRichText, "entry \(want.id) rich text presence")
        }
        XCTAssertEqual(view.DeletedEntries.count, expected.deleted.count, "view tombstone count")

        // The images channel is unsubscribed: none of its entries may appear.
        for entry in images.Entries {
            XCTAssertFalse(
                view.Entries.contains { $0.Id.lowercased() == entry.Id.lowercased() },
                "an unsubscribed channel's entry leaked into the view"
            )
        }
    }

    /// The corpus manifest carries the published identity vectors; deriving
    /// them here proves this client would poll exactly the buckets the
    /// generator wrote.
    func testGoSyncRulesFixtureBucketIdentitiesMatchTheManifest() throws {
        _ = try corpusDirectory()
        let token = "example-token"
        XCTAssertEqual(
            ServerDatabaseIdentity.fromTokenAndPassword(token: token, password: password),
            "l4GLcFU7RrlmkGXoRyQ7-zVG5D5S0VmfwO6-dGNmebU"
        )
        XCTAssertEqual(
            ServerDatabaseIdentity.syncRulesDatabaseId(token: token, password: password),
            "j5Z6kOIWgsJMqS0IRzNJEq38aqJ-iA8e6yzyX0W71WQ"
        )
        XCTAssertEqual(
            ServerDatabaseIdentity.channelDatabaseId(token: token, password: password, channelKey: "work"),
            "F0MZBlui50Vd37JVf-JcvOWvoHV71IDlQE5OnfVBKeA"
        )
        XCTAssertEqual(
            ServerDatabaseIdentity.channelDatabaseId(token: token, password: password, channelKey: "images"),
            "K_hH97mxfF4_DQvN90Orzu_HUz7MOcKYoL3-6nY-TbQ"
        )
    }
}
