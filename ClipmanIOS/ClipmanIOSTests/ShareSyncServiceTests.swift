import XCTest
@testable import ClipmanIOS

final class ShareSyncServiceTests: XCTestCase {
    func testSharedConfigurationContainsNoSecrets() throws {
        let configuration = ShareSyncConfiguration(
            storageMode: "server",
            serverURL: "clipman://example.test:12345/",
            serverCaCertPEM: "certificate",
            serverCaHost: "example.test",
            deviceName: "Test Phone",
            richTextEnabled: true,
            includeImagesInRichText: false
        )
        let data = try JSONEncoder().encode(configuration)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("password"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("token"))
        XCTAssertEqual(try JSONDecoder().decode(ShareSyncConfiguration.self, from: data), configuration)
    }

    func testShareMutationAddsTextWithDeviceName() throws {
        let payload = MobileClipboardPayload(text: "Shared text", richText: nil, importError: nil)
        let result = try ShareSyncDatabaseMutation.applying(
            payload: payload,
            to: ClipDatabase(),
            settings: settings()
        )
        XCTAssertFalse(result.alreadyExists)
        XCTAssertEqual(result.database.Entries.count, 1)
        XCTAssertEqual(result.database.Entries[0].Text, "Shared text")
        XCTAssertEqual(result.database.Entries[0].SourceMachine, "Test Phone")
    }

    func testShareMutationRecognizesExistingText() throws {
        let database = ClipDatabase(Entries: [ClipEntry(Text: "Shared text")])
        let payload = MobileClipboardPayload(text: "Shared text", richText: nil, importError: nil)
        let result = try ShareSyncDatabaseMutation.applying(
            payload: payload,
            to: database,
            settings: settings()
        )
        XCTAssertTrue(result.alreadyExists)
        XCTAssertEqual(result.database.Entries.count, 1)
    }

    func testShareMutationKeepsHTMLWhenRichTextIsEnabled() throws {
        let richText = RichTextPayload(
            HtmlFragment: "<p><strong>Shared text</strong></p>",
            PreferredFormat: "Html"
        )
        let payload = MobileClipboardPayload(text: "Shared text", richText: richText, importError: nil)
        let result = try ShareSyncDatabaseMutation.applying(
            payload: payload,
            to: ClipDatabase(),
            settings: settings(richTextEnabled: true)
        )
        XCTAssertEqual(result.database.Entries[0].RichText, richText)
    }

    func testShareRoutesImageToImagesChannel() async throws {
        let shareSettings = settings(richTextEnabled: true)
        let rules = SyncRulesDocument(
            Clipman: "sync-rules",
            Version: 1,
            Enabled: true,
            UpdatedUnixMs: 1,
            UpdatedBy: "Desktop",
            Channels: [SyncChannel(Name: "Images", Route: SyncRoute(Kind: "RichTextImages"))],
            Devices: [SyncDevice(Name: "Test Phone", Channels: ["*"])]
        )
        let payload = MobileClipboardPayload(
            text: "Shared photo",
            richText: RichTextPayload(
                HtmlFragment: "<p><img src=\"data:image/png;base64,AAAA\"></p>",
                PreferredFormat: "Html"
            ),
            importError: nil
        )
        XCTAssertEqual(
            ShareSyncService.targetChannelKey(payload: payload, settings: shareSettings, rules: rules),
            "images"
        )

        let expectedID = ServerDatabaseIdentity.channelDatabaseId(
            token: "test-token",
            password: "test-password",
            channelKey: "images"
        )
        let bucket = FakeShareBucket(databaseID: expectedID)
        let result = try await ShareSyncService().synchronize(
            payload: payload,
            settings: shareSettings,
            rules: rules
        ) { channelKey in
            XCTAssertEqual(channelKey, "images")
            return bucket
        }

        XCTAssertEqual(result, .added)
        let uploadedData = await bucket.uploadedData()
        let uploaded = try XCTUnwrap(uploadedData)
        let database = try ClipDatabaseFile.load(uploaded, password: "test-password")
        XCTAssertEqual(database.Entries.map(\.Text), ["Shared photo"])
        let usedCreateOnly = await bucket.createOnlyUpload()
        XCTAssertTrue(usedCreateOnly)
        // The channel bucket the routed write lands in is the derived one, so
        // every client writes the same shared item to the same bucket.
        let resolved = try ShareSyncService.serverBucket(channelKey: "images", settings: shareSettings)
        XCTAssertEqual(resolved.databaseID, expectedID)
        XCTAssertFalse(expectedID.isEmpty)
    }

    func testShareFallsBackToCoreWithoutRules() async throws {
        let shareSettings = settings()
        let payload = MobileClipboardPayload(text: "Shared text", richText: nil, importError: nil)
        let coreID = ServerDatabaseIdentity.fromTokenAndPassword(token: "test-token", password: "test-password")
        let bucket = FakeShareBucket(databaseID: coreID)
        let result = try await ShareSyncService().synchronize(
            payload: payload,
            settings: shareSettings,
            rules: nil
        ) { channelKey in
            XCTAssertTrue(channelKey.isEmpty)
            return bucket
        }

        XCTAssertEqual(result, .added)
        let uploadedData = await bucket.uploadedData()
        let uploaded = try XCTUnwrap(uploadedData)
        let database = try ClipDatabaseFile.load(uploaded, password: "test-password")
        XCTAssertEqual(database.Entries.map(\.Text), ["Shared text"])
        // Core keeps its historical create behavior: no If-None-Match.
        let usedCreateOnly = await bucket.createOnlyUpload()
        XCTAssertFalse(usedCreateOnly)
        let resolved = try ShareSyncService.serverBucket(channelKey: "", settings: shareSettings)
        XCTAssertEqual(resolved.databaseID, coreID)
    }

    func testShareRoutesToCoreWhenNoRuleMatches() {
        let rules = SyncRulesDocument(
            Clipman: "sync-rules",
            Version: 1,
            Enabled: true,
            UpdatedUnixMs: 1,
            UpdatedBy: "Desktop",
            Channels: [SyncChannel(Name: "Work", Route: SyncRoute(Groups: ["Work"]))],
            Devices: []
        )
        let payload = MobileClipboardPayload(text: "Shared text", richText: nil, importError: nil)
        // Shared items carry no group, so a group route can never claim them.
        XCTAssertEqual(
            ShareSyncService.targetChannelKey(payload: payload, settings: settings(), rules: rules),
            ""
        )
    }

    private func settings(richTextEnabled: Bool = false) -> ShareSyncSettings {
        ShareSyncSettings(
            serverURL: "clipman://example.test:12345/",
            serverToken: "test-token",
            serverCaCertPEM: "",
            serverCaHost: "",
            historyPassword: "test-password",
            deviceName: "Test Phone",
            richTextEnabled: richTextEnabled,
            includeImagesInRichText: false
        )
    }
}

/// A Clipman Server bucket that exists only in memory, so the Share extension's
/// routing and upload path can be exercised without a server.
private actor FakeShareBucket: ShareSyncBucket {
    nonisolated let databaseID: String
    private var uploaded: Data?
    private var createOnly = false

    init(databaseID: String) {
        self.databaseID = databaseID
    }

    func download() async throws -> ServerDatabaseDownload {
        throw ServerStorageError.notFound
    }

    func upload(data: Data, expectedRevision: String, createOnly: Bool) async throws -> String {
        uploaded = data
        self.createOnly = createOnly
        return "revision-1"
    }

    func uploadedData() -> Data? { uploaded }

    func createOnlyUpload() -> Bool { createOnly }
}
