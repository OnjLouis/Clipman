import XCTest
@testable import Clipman

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

    func testStartupCaptureDoesNotRetouchExistingEntry() {
        let original = ClipEntry(
            Text: "Shared text",
            Name: "Original name",
            Group: "Original group",
            SourceMachine: "Windows",
            CreatedUnixMs: 100,
            LastUsedUnixMs: 200,
            ModifiedUnixMs: 150
        )

        let result = SyncConflictResolver.addText(
            database: ClipDatabase(Entries: [original]),
            text: original.Text,
            machineName: "iPhone",
            preserveExistingMetadata: true
        )

        XCTAssertEqual(result.Entries, [original])
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

final class QuickActionTests: XCTestCase {
    @MainActor
    func testQuickClipActionWaitsUntilTheAppConsumesIt() {
        let center = ClipmanQuickActionCenter()
        center.request(.quickClip)

        XCTAssertEqual(center.pendingAction, .quickClip)
        XCTAssertEqual(center.consume(), .quickClip)
        XCTAssertNil(center.pendingAction)
    }
}
