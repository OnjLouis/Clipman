import XCTest
@testable import ClipmanCore

/// Cross-client conformance tests for sync-rules-spec.md sections 2 to 4. The
/// fixtures here are the same ones the Go and Windows clients use, so a change
/// that makes one client route or address differently fails here first.
final class SyncRulesTests: XCTestCase {
    private let token = "example-token"
    private let historyPassword = "example-password"

    // MARK: - Section 2, bucket identity

    func testBucketIdentityMatchesTheCrossClientVectors() {
        XCTAssertEqual(
            ServerDatabaseIdentity.fromTokenAndPassword(token: token, password: historyPassword),
            "l4GLcFU7RrlmkGXoRyQ7-zVG5D5S0VmfwO6-dGNmebU"
        )
        XCTAssertEqual(
            ServerDatabaseIdentity.syncRulesDatabaseId(token: token, password: historyPassword),
            "j5Z6kOIWgsJMqS0IRzNJEq38aqJ-iA8e6yzyX0W71WQ"
        )
        XCTAssertEqual(
            ServerDatabaseIdentity.channelDatabaseId(token: token, password: historyPassword, channelKey: "work"),
            "F0MZBlui50Vd37JVf-JcvOWvoHV71IDlQE5OnfVBKeA"
        )
        XCTAssertEqual(
            ServerDatabaseIdentity.channelDatabaseId(token: token, password: historyPassword, channelKey: "images"),
            "K_hH97mxfF4_DQvN90Orzu_HUz7MOcKYoL3-6nY-TbQ"
        )
        XCTAssertEqual(
            ServerDatabaseIdentity.channelDatabaseId(token: token, password: historyPassword, channelKey: "desktop only"),
            "02tgOt5QC_sWY2RmoI2pqII9MocLQ7-XIMHaSRVBE1o"
        )
    }

    func testBucketIdentityTrimsInputsAndRefusesBlankOnes() {
        XCTAssertEqual(
            ServerDatabaseIdentity.channelDatabaseId(token: "  \(token)\n", password: historyPassword, channelKey: " work "),
            "F0MZBlui50Vd37JVf-JcvOWvoHV71IDlQE5OnfVBKeA"
        )
        XCTAssertEqual(ServerDatabaseIdentity.channelDatabaseId(token: "", password: historyPassword, channelKey: "work"), "")
        XCTAssertEqual(ServerDatabaseIdentity.channelDatabaseId(token: token, password: "", channelKey: "work"), "")
        XCTAssertEqual(ServerDatabaseIdentity.channelDatabaseId(token: token, password: historyPassword, channelKey: ""), "")
        XCTAssertEqual(ServerDatabaseIdentity.syncRulesDatabaseId(token: token, password: ""), "")
    }

    func testSharedFolderFileNames() {
        XCTAssertEqual(SyncRuleEngine.channelFileName("work"), "clipman-channel-work.clipdb")
        XCTAssertEqual(SyncRuleEngine.channelFileName("desktop only"), "clipman-channel-desktop-only.clipdb")
        XCTAssertEqual(SyncRuleEngine.syncRulesFileName, "clipman-sync-rules.clipdb")
    }

    // MARK: - Section 3, channel keys

    func testChannelKeyGrammar() {
        XCTAssertEqual(SyncRuleEngine.channelKey("Work"), "work")
        XCTAssertEqual(SyncRuleEngine.channelKey("  Desktop Only  "), "desktop only")
        XCTAssertEqual(SyncRuleEngine.channelKey("a"), "a")
        XCTAssertEqual(SyncRuleEngine.channelKey("9"), "9")
        XCTAssertEqual(SyncRuleEngine.channelKey("a_b-c 1"), "a_b-c 1")
        XCTAssertEqual(SyncRuleEngine.channelKey(String(repeating: "a", count: 32)), String(repeating: "a", count: 32))

        XCTAssertEqual(SyncRuleEngine.channelKey(""), "")
        XCTAssertEqual(SyncRuleEngine.channelKey("   "), "")
        XCTAssertEqual(SyncRuleEngine.channelKey("-work"), "")
        XCTAssertEqual(SyncRuleEngine.channelKey("work-"), "")
        XCTAssertEqual(SyncRuleEngine.channelKey("_work"), "")
        XCTAssertEqual(SyncRuleEngine.channelKey("work_"), "")
        XCTAssertEqual(SyncRuleEngine.channelKey("wörk"), "")
        XCTAssertEqual(SyncRuleEngine.channelKey("work!"), "")
        XCTAssertEqual(SyncRuleEngine.channelKey("wo/rk"), "")
        XCTAssertEqual(SyncRuleEngine.channelKey(String(repeating: "a", count: 33)), "")
    }

    // MARK: - Section 4, validation

    func testValidateAcceptsTheSpecExample() {
        XCTAssertNil(SyncRuleEngine.validate(exampleDocument()))
    }

    func testValidateRejectsReservedDuplicateAndConditionlessChannels() {
        var reserved = exampleDocument()
        reserved.Channels = [SyncChannel(Name: "core", Route: SyncRoute(Groups: ["Work"]))]
        reserved.Devices = []
        XCTAssertNotNil(SyncRuleEngine.validate(reserved))

        var duplicate = exampleDocument()
        duplicate.Channels = [
            SyncChannel(Name: "Work", Route: SyncRoute(Groups: ["Work"])),
            SyncChannel(Name: "  work ", Route: SyncRoute(Groups: ["Other"]))
        ]
        duplicate.Devices = []
        XCTAssertNotNil(SyncRuleEngine.validate(duplicate))

        var conditionless = exampleDocument()
        conditionless.Channels = [SyncChannel(Name: "Work", Route: SyncRoute())]
        conditionless.Devices = []
        XCTAssertNotNil(SyncRuleEngine.validate(conditionless))

        var unsupportedKind = exampleDocument()
        unsupportedKind.Channels = [SyncChannel(Name: "Work", Route: SyncRoute(Kind: "Screenshots"))]
        unsupportedKind.Devices = []
        XCTAssertNotNil(SyncRuleEngine.validate(unsupportedKind))
    }

    func testValidateRejectsForeignDocumentsAndBadDeviceReferences() {
        var foreign = exampleDocument()
        foreign.Clipman = "something-else"
        XCTAssertNotNil(SyncRuleEngine.validate(foreign))

        var unknownChannel = exampleDocument()
        unknownChannel.Devices = [SyncDevice(Name: "Laptop", Channels: ["archive"])]
        XCTAssertNotNil(SyncRuleEngine.validate(unknownChannel))

        var mixedWildcard = exampleDocument()
        mixedWildcard.Devices = [SyncDevice(Name: "Laptop", Channels: ["*", "work"])]
        XCTAssertNotNil(SyncRuleEngine.validate(mixedWildcard))

        var soleWildcard = exampleDocument()
        soleWildcard.Devices = [SyncDevice(Name: "Laptop", Channels: ["*"])]
        XCTAssertNil(SyncRuleEngine.validate(soleWildcard))
    }

    // MARK: - Section 4, routing

    func testRoutingTakesTheFirstMatchingChannel() {
        let document = exampleDocument()
        XCTAssertEqual(SyncRuleEngine.route(document: document, entry: entry(group: "work")), "work")
        // Groups are matched case-insensitively after trimming.
        XCTAssertEqual(SyncRuleEngine.route(document: document, entry: entry(group: "  WORK ")), "work")
        XCTAssertEqual(SyncRuleEngine.route(document: document, entry: entry(group: "Standup")), "work")
        XCTAssertEqual(SyncRuleEngine.route(document: document, entry: entry(source: "work-pc")), "desktop only")
        XCTAssertEqual(SyncRuleEngine.route(document: document, entry: entry(html: "<img src=\"data:image/png;base64,AA\">")), "images")
        // Images is listed first, so an entry that matches both lands there.
        XCTAssertEqual(
            SyncRuleEngine.route(document: document, entry: entry(group: "Work", html: "<img src=\"data:image/png;base64,AA\">")),
            "images"
        )
        XCTAssertEqual(SyncRuleEngine.route(document: document, entry: entry(group: "Personal")), "")
        XCTAssertEqual(SyncRuleEngine.route(document: document, entry: entry()), "")
    }

    func testRoutingAndsTheConditionsOfOneRoute() {
        var document = exampleDocument()
        document.Channels = [
            SyncChannel(Name: "Work", Route: SyncRoute(Groups: ["Work"], SourceDevices: ["Desktop"]))
        ]
        document.Devices = []
        XCTAssertEqual(SyncRuleEngine.route(document: document, entry: entry(group: "Work", source: "Desktop")), "work")
        XCTAssertEqual(SyncRuleEngine.route(document: document, entry: entry(group: "Work", source: "Laptop")), "")
        XCTAssertEqual(SyncRuleEngine.route(document: document, entry: entry(group: "Personal", source: "Desktop")), "")
    }

    func testRoutingIsInertWhenRulesAreMissingOrDisabled() {
        var disabled = exampleDocument()
        disabled.Enabled = false
        XCTAssertEqual(SyncRuleEngine.route(document: disabled, entry: entry(group: "Work")), "")
        XCTAssertEqual(SyncRuleEngine.route(document: nil, entry: entry(group: "Work")), "")
        XCTAssertEqual(SyncRuleEngine.route(document: exampleDocument(), entry: nil), "")
    }

    func testRichTextImagesKindIsSafeOnMalformedRichText() {
        var document = exampleDocument()
        document.Channels = [SyncChannel(Name: "Images", Route: SyncRoute(Kind: SyncRuleEngine.richTextImagesKind))]
        document.Devices = []

        XCTAssertEqual(SyncRuleEngine.route(document: document, entry: entry()), "")
        XCTAssertEqual(SyncRuleEngine.route(document: document, entry: entry(html: "")), "")
        XCTAssertEqual(SyncRuleEngine.route(document: document, entry: entry(html: "<p>no image here</p>")), "")
        XCTAssertEqual(SyncRuleEngine.route(document: document, entry: entry(html: "<img src='DATA:IMAGE/png;base64,AA'>")), "")
        XCTAssertEqual(SyncRuleEngine.route(document: document, entry: entry(html: "prefix data:image/gif;base64,AA suffix")), "images")

        var unknownKind = document
        unknownKind.Channels = [SyncChannel(Name: "Images", Route: SyncRoute(Kind: "Screenshots"))]
        XCTAssertEqual(
            SyncRuleEngine.route(document: unknownKind, entry: entry(html: "<img src=\"data:image/png;base64,AA\">")),
            ""
        )
    }

    // MARK: - Section 4, subscriptions

    func testSubscriptions() {
        let document = exampleDocument()
        // An unlisted device subscribes to everything, which is expressed as nil.
        XCTAssertNil(SyncRuleEngine.subscribedChannels(document: document, deviceName: "Unknown-Laptop"))
        XCTAssertEqual(
            SyncRuleEngine.subscribedChannels(document: document, deviceName: "Desktop"),
            ["images", "work", "desktop only"]
        )
        XCTAssertEqual(SyncRuleEngine.subscribedChannels(document: document, deviceName: "  jeff-iphone "), ["work"])
        XCTAssertEqual(
            SyncRuleEngine.subscribedChannels(document: document, deviceName: "Work-PC"),
            ["work", "desktop only"]
        )

        var disabled = document
        disabled.Enabled = false
        XCTAssertNil(SyncRuleEngine.subscribedChannels(document: disabled, deviceName: "Desktop"))
        XCTAssertNil(SyncRuleEngine.subscribedChannels(document: nil, deviceName: "Desktop"))
    }

    func testSubscribedKeysFollowDocumentOrder() {
        let document = exampleDocument()
        XCTAssertEqual(SyncRuleEngine.subscribedKeys(document: document, deviceName: "Work-PC"), ["work", "desktop only"])
        XCTAssertEqual(
            SyncRuleEngine.subscribedKeys(document: document, deviceName: "Unknown-Laptop"),
            ["images", "work", "desktop only"]
        )
        var disabled = document
        disabled.Enabled = false
        XCTAssertEqual(SyncRuleEngine.subscribedKeys(document: disabled, deviceName: "Desktop"), [])
    }

    // MARK: - Section 4, merge

    func testMergeIsLastWriterWinsWithAnOrdinalTieBreak() {
        var older = exampleDocument()
        older.UpdatedUnixMs = 1_000
        older.UpdatedBy = "Zebra"
        var newer = exampleDocument()
        newer.UpdatedUnixMs = 2_000
        newer.UpdatedBy = "Alpha"

        XCTAssertEqual(SyncRuleEngine.merge(local: older, remote: newer)?.UpdatedBy, "Alpha")
        XCTAssertEqual(SyncRuleEngine.merge(local: newer, remote: older)?.UpdatedBy, "Alpha")

        var tieLow = exampleDocument()
        tieLow.UpdatedUnixMs = 5_000
        tieLow.UpdatedBy = "Alpha"
        var tieHigh = exampleDocument()
        tieHigh.UpdatedUnixMs = 5_000
        tieHigh.UpdatedBy = "Beta"
        XCTAssertEqual(SyncRuleEngine.merge(local: tieLow, remote: tieHigh)?.UpdatedBy, "Beta")
        // The local copy keeps a true tie, so the merge is stable.
        XCTAssertEqual(SyncRuleEngine.merge(local: tieHigh, remote: tieLow)?.UpdatedBy, "Beta")
        XCTAssertEqual(SyncRuleEngine.merge(local: tieHigh, remote: tieHigh)?.UpdatedBy, "Beta")

        XCTAssertEqual(SyncRuleEngine.merge(local: nil, remote: tieHigh)?.UpdatedBy, "Beta")
        XCTAssertEqual(SyncRuleEngine.merge(local: tieHigh, remote: nil)?.UpdatedBy, "Beta")
        XCTAssertNil(SyncRuleEngine.merge(local: nil, remote: nil))
    }

    // MARK: - Encoding

    func testCodableRoundTripKeepsEveryField() throws {
        let original = exampleDocument()
        let data = try XCTUnwrap(SyncRuleEngine.serialize(original))
        let decoded = try XCTUnwrap(SyncRuleEngine.parse(data))
        XCTAssertEqual(decoded, original)
    }

    func testEncodingOmitsEmptyRouteConditions() throws {
        let document = SyncRulesDocument(
            Clipman: SyncRuleEngine.documentKind,
            Version: 1,
            Enabled: true,
            UpdatedUnixMs: 1,
            UpdatedBy: "Desktop",
            Channels: [SyncChannel(Name: "Images", Route: SyncRoute(Kind: SyncRuleEngine.richTextImagesKind))],
            Devices: []
        )
        let data = try XCTUnwrap(SyncRuleEngine.serialize(document))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"Kind\":\"RichTextImages\""))
        XCTAssertFalse(text.contains("Groups"))
        XCTAssertFalse(text.contains("SourceDevices"))
    }

    func testParsesTheSpecExamplePayload() throws {
        let payload = """
        {
          "Clipman": "sync-rules",
          "Version": 1,
          "Enabled": true,
          "UpdatedUnixMs": 1757200000000,
          "UpdatedBy": "Desktop",
          "Channels": [
            { "Name": "Images",       "Route": { "Kind": "RichTextImages" } },
            { "Name": "Work",         "Route": { "Groups": ["Work", "Standup"] } },
            { "Name": "Desktop only", "Route": { "SourceDevices": ["Desktop", "Work-PC"] } }
          ],
          "Devices": [
            { "Name": "Desktop",     "Channels": ["*"] },
            { "Name": "Jeff-iPhone", "Channels": ["work"] },
            { "Name": "Work-PC",     "Channels": ["work", "desktop only"] }
          ]
        }
        """
        let document = try XCTUnwrap(SyncRuleEngine.parse(Data(payload.utf8)))
        XCTAssertEqual(document, exampleDocument())
        XCTAssertFalse(SyncRuleEngine.isReadOnly(document))
    }

    func testParseRejectsForeignAndInvalidCurrentVersionDocuments() {
        XCTAssertNil(SyncRuleEngine.parse(Data("{\"Clipman\":\"clip-history\",\"Version\":1}".utf8)))
        XCTAssertNil(SyncRuleEngine.parse(Data("not json".utf8)))
        XCTAssertNil(SyncRuleEngine.parse(Data("""
        {"Clipman":"sync-rules","Version":1,"Channels":[{"Name":"core","Route":{"Groups":["Work"]}}]}
        """.utf8)))
    }

    // MARK: - Section 4, future versions

    func testFutureVersionDocumentsAreAcceptedReadOnlyAndAppliedLeniently() throws {
        let payload = """
        {
          "Clipman": "sync-rules",
          "Version": 7,
          "Enabled": true,
          "UpdatedUnixMs": 42,
          "UpdatedBy": "Future",
          "Channels": [
            { "Name": "Wörk",  "Route": { "Groups": ["Work"] } },
            { "Name": "Later", "Route": { "Kind": "Holograms" } },
            { "Name": "Work",  "Route": { "Groups": ["Work"] } }
          ],
          "Devices": [ { "Name": "Desktop", "Channels": ["work", "not-a-channel"] } ]
        }
        """
        let document = try XCTUnwrap(SyncRuleEngine.parse(Data(payload.utf8)))
        XCTAssertTrue(SyncRuleEngine.isReadOnly(document))
        XCTAssertTrue(SyncRuleEngine.isUsable(document))
        // Strict validation would have rejected it; a future document is applied
        // where it is understood instead of failing the client entirely.
        XCTAssertNotNil(SyncRuleEngine.validate(document))

        // The unnamed channel is unroutable, the unknown kind never matches, and
        // an unresolvable device reference is dropped.
        XCTAssertEqual(SyncRuleEngine.allChannelKeys(document), ["later", "work"])
        XCTAssertEqual(SyncRuleEngine.subscribedChannels(document: document, deviceName: "Desktop"), ["work"])
        XCTAssertEqual(SyncRuleEngine.subscribedKeys(document: document, deviceName: "Desktop"), ["work"])
    }

    func testReadOnlyAndUsabilityBoundaries() {
        var current = exampleDocument()
        current.Version = 1
        XCTAssertFalse(SyncRuleEngine.isReadOnly(current))
        XCTAssertTrue(SyncRuleEngine.isUsable(current))

        var future = exampleDocument()
        future.Version = 2
        XCTAssertTrue(SyncRuleEngine.isReadOnly(future))

        var foreign = exampleDocument()
        foreign.Clipman = "clip-history"
        XCTAssertFalse(SyncRuleEngine.isUsable(foreign))
        XCTAssertFalse(SyncRuleEngine.isReadOnly(nil))
        XCTAssertFalse(SyncRuleEngine.isUsable(nil))
    }

    func testChannelDisplayNameLookup() {
        let document = exampleDocument()
        XCTAssertEqual(SyncRuleEngine.channelName(document, key: "desktop only"), "Desktop only")
        XCTAssertEqual(SyncRuleEngine.channelName(document, key: "unknown"), "unknown")
        XCTAssertEqual(SyncRuleEngine.channelName(document, key: ""), "the main history")
    }

    // MARK: - Fixtures

    private func exampleDocument() -> SyncRulesDocument {
        SyncRulesDocument(
            Clipman: SyncRuleEngine.documentKind,
            Version: 1,
            Enabled: true,
            UpdatedUnixMs: 1_757_200_000_000,
            UpdatedBy: "Desktop",
            Channels: [
                SyncChannel(Name: "Images", Route: SyncRoute(Kind: SyncRuleEngine.richTextImagesKind)),
                SyncChannel(Name: "Work", Route: SyncRoute(Groups: ["Work", "Standup"])),
                SyncChannel(Name: "Desktop only", Route: SyncRoute(SourceDevices: ["Desktop", "Work-PC"]))
            ],
            Devices: [
                SyncDevice(Name: "Desktop", Channels: ["*"]),
                SyncDevice(Name: "Jeff-iPhone", Channels: ["work"]),
                SyncDevice(Name: "Work-PC", Channels: ["work", "desktop only"])
            ]
        )
    }

    private func entry(group: String = "", source: String = "", html: String? = nil) -> ClipEntry {
        ClipEntry(
            Id: "abc123",
            Text: "sample",
            Group: group,
            SourceMachine: source,
            CreatedUnixMs: 1_000,
            LastUsedUnixMs: 1_000,
            ModifiedUnixMs: 1_000,
            RichText: html.map { RichTextPayload(Version: 1, HtmlFragment: $0) }
        )
    }
}
