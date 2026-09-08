import XCTest
@testable import Clipman

final class SyncRulesTests: XCTestCase {
    private let token = "example-token"
    private let password = "example-password"

    // MARK: - Bucket identity (sync-rules-spec.md section 2)

    func testExistingDatabaseIdentityIsUnchanged() {
        XCTAssertEqual(
            ServerDatabaseIdentity.fromTokenAndPassword(token: token, password: password),
            "l4GLcFU7RrlmkGXoRyQ7-zVG5D5S0VmfwO6-dGNmebU"
        )
    }

    func testSyncRulesDatabaseIdentityMatchesCrossClientVector() {
        XCTAssertEqual(
            ServerDatabaseIdentity.syncRulesDatabaseId(token: token, password: password),
            "j5Z6kOIWgsJMqS0IRzNJEq38aqJ-iA8e6yzyX0W71WQ"
        )
    }

    func testChannelDatabaseIdentityMatchesCrossClientVectors() {
        XCTAssertEqual(
            ServerDatabaseIdentity.channelDatabaseId(token: token, password: password, channelKey: "work"),
            "F0MZBlui50Vd37JVf-JcvOWvoHV71IDlQE5OnfVBKeA"
        )
        XCTAssertEqual(
            ServerDatabaseIdentity.channelDatabaseId(token: token, password: password, channelKey: "images"),
            "K_hH97mxfF4_DQvN90Orzu_HUz7MOcKYoL3-6nY-TbQ"
        )
        XCTAssertEqual(
            ServerDatabaseIdentity.channelDatabaseId(token: token, password: password, channelKey: "desktop only"),
            "02tgOt5QC_sWY2RmoI2pqII9MocLQ7-XIMHaSRVBE1o"
        )
    }

    func testChannelIdentityTrimsAndRequiresCredentials() {
        XCTAssertEqual(
            ServerDatabaseIdentity.channelDatabaseId(token: "  \(token)  ", password: password, channelKey: " work "),
            "F0MZBlui50Vd37JVf-JcvOWvoHV71IDlQE5OnfVBKeA"
        )
        XCTAssertEqual(ServerDatabaseIdentity.channelDatabaseId(token: "", password: password, channelKey: "work"), "")
        XCTAssertEqual(ServerDatabaseIdentity.channelDatabaseId(token: token, password: "", channelKey: "work"), "")
        XCTAssertEqual(ServerDatabaseIdentity.channelDatabaseId(token: token, password: password, channelKey: ""), "")
        XCTAssertEqual(ServerDatabaseIdentity.syncRulesDatabaseId(token: token, password: ""), "")
    }

    // MARK: - Channel key grammar (section 3)

    func testChannelKeyGrammarAcceptsSpecExamples() {
        XCTAssertEqual(SyncRuleEngine.channelKey("Work"), "work")
        XCTAssertEqual(SyncRuleEngine.channelKey("  Desktop only  "), "desktop only")
        XCTAssertEqual(SyncRuleEngine.channelKey("a"), "a")
        XCTAssertEqual(SyncRuleEngine.channelKey("a1_b-c 9"), "a1_b-c 9")
        XCTAssertEqual(SyncRuleEngine.channelKey(String(repeating: "a", count: 32)), String(repeating: "a", count: 32))
    }

    func testChannelKeyGrammarRejectsInvalidNames() {
        for name in ["", "   ", "-work", "work-", "_work", "work_", " work-",
                     "wörk", "work!", String(repeating: "a", count: 33)] {
            XCTAssertEqual(SyncRuleEngine.channelKey(name), "", "expected \"\(name)\" to be rejected")
        }
    }

    func testValidateRejectsReservedAndDuplicateChannels() {
        for reserved in ["core", "All", "pinned", "sync-rules"] {
            let document = document(channels: [SyncChannel(Name: reserved, Route: SyncRoute(Groups: ["Work"]))])
            XCTAssertNotNil(SyncRuleEngine.validate(document), "expected \"\(reserved)\" to be reserved")
        }
        let duplicate = document(channels: [
            SyncChannel(Name: "Work", Route: SyncRoute(Groups: ["Work"])),
            SyncChannel(Name: "work", Route: SyncRoute(Groups: ["Other"]))
        ])
        XCTAssertNotNil(SyncRuleEngine.validate(duplicate))
    }

    func testValidateRejectsEmptyAndUnknownRoutes() {
        XCTAssertNotNil(SyncRuleEngine.validate(document(channels: [SyncChannel(Name: "Work", Route: SyncRoute())])))
        XCTAssertNotNil(SyncRuleEngine.validate(document(channels: [
            SyncChannel(Name: "Work", Route: SyncRoute(Kind: "Video"))
        ])))
        XCTAssertNil(SyncRuleEngine.validate(routingDocument()))
    }

    func testValidateRejectsWrongDocumentMarker() throws {
        var wrong = routingDocument()
        wrong.Clipman = "clip-rules"
        XCTAssertNotNil(SyncRuleEngine.validate(wrong))
        XCTAssertFalse(SyncRuleEngine.isUsable(wrong))
        XCTAssertNil(SyncRuleEngine.parse(try JSONEncoder().encode(wrong)))
    }

    // MARK: - Routing (section 4)

    func testRoutingHonorsFirstMatchInDocumentOrder() {
        let document = routingDocument()
        var entry = ClipEntry(Text: "screenshot", Group: "Work", SourceMachine: "Desktop")
        entry.RichText = RichTextPayload(HtmlFragment: "<img src=\"data:image/png;base64,AA\">")
        // Images is listed first, so it wins over Work and Desktop only.
        XCTAssertEqual(SyncRuleEngine.route(document: document, entry: entry), "images")
    }

    func testRoutingMatchesGroupsAndDevicesCaseInsensitively() {
        let document = routingDocument()
        XCTAssertEqual(
            SyncRuleEngine.route(document: document, entry: ClipEntry(Text: "a", Group: "  wOrK ")),
            "work"
        )
        XCTAssertEqual(
            SyncRuleEngine.route(document: document, entry: ClipEntry(Text: "a", SourceMachine: "work-pc")),
            "desktop only"
        )
        XCTAssertEqual(
            SyncRuleEngine.route(document: document, entry: ClipEntry(Text: "a", Group: "Personal")),
            ""
        )
    }

    func testRoutingAndsConditionsWithinOneRoute() {
        let document = document(channels: [
            SyncChannel(Name: "Both", Route: SyncRoute(Groups: ["Work"], SourceDevices: ["Desktop"]))
        ])
        XCTAssertEqual(
            SyncRuleEngine.route(document: document, entry: ClipEntry(Text: "a", Group: "Work", SourceMachine: "Desktop")),
            "both"
        )
        XCTAssertEqual(
            SyncRuleEngine.route(document: document, entry: ClipEntry(Text: "a", Group: "Work", SourceMachine: "Laptop")),
            ""
        )
        XCTAssertEqual(
            SyncRuleEngine.route(document: document, entry: ClipEntry(Text: "a", Group: "Personal", SourceMachine: "Desktop")),
            ""
        )
    }

    func testRichTextImagesMatchesOnlyEmbeddedImages() {
        let document = document(channels: [
            SyncChannel(Name: "Images", Route: SyncRoute(Kind: SyncRuleEngine.richTextImagesKind))
        ])
        var plainRichText = ClipEntry(Text: "styled")
        plainRichText.RichText = RichTextPayload(HtmlFragment: "<p><strong>styled</strong></p>")
        XCTAssertEqual(SyncRuleEngine.route(document: document, entry: plainRichText), "")

        var embedded = ClipEntry(Text: "photo")
        embedded.RichText = RichTextPayload(HtmlFragment: "<p><img src=\"data:image/jpeg;base64,AA\"></p>")
        XCTAssertEqual(SyncRuleEngine.route(document: document, entry: embedded), "images")

        XCTAssertEqual(SyncRuleEngine.route(document: document, entry: ClipEntry(Text: "plain")), "")
    }

    func testUnknownRouteKindNeverMatches() {
        // Only a future-version document can carry an unknown kind, and such a
        // document is applied leniently rather than rejected.
        var future = document(channels: [SyncChannel(Name: "Video", Route: SyncRoute(Kind: "Video"))])
        future.Version = 2
        var entry = ClipEntry(Text: "clip", Group: "Work", SourceMachine: "Desktop")
        entry.RichText = RichTextPayload(HtmlFragment: "<img src=\"data:image/png;base64,AA\">")
        XCTAssertEqual(SyncRuleEngine.route(document: future, entry: entry), "")
    }

    func testDisabledDocumentRoutesEverythingToCore() {
        var disabled = routingDocument()
        disabled.Enabled = false
        XCTAssertEqual(
            SyncRuleEngine.route(document: disabled, entry: ClipEntry(Text: "a", Group: "Work")),
            ""
        )
        XCTAssertEqual(SyncRuleEngine.route(document: nil, entry: ClipEntry(Text: "a", Group: "Work")), "")
    }

    // MARK: - Subscriptions (section 4)

    func testSubscriptionsResolveNamedChannelsAndWildcards() {
        let document = routingDocument()
        XCTAssertEqual(
            SyncRuleEngine.subscribedChannels(document: document, deviceName: "jeff-iphone"),
            ["work"]
        )
        XCTAssertEqual(
            SyncRuleEngine.subscribedChannels(document: document, deviceName: " Desktop "),
            ["images", "work", "desktop only"]
        )
        XCTAssertEqual(
            SyncRuleEngine.subscribedKeys(document: document, deviceName: "Work-PC"),
            ["work", "desktop only"]
        )
    }

    func testUnlistedDeviceSubscribesToEverything() {
        let document = routingDocument()
        XCTAssertNil(SyncRuleEngine.subscribedChannels(document: document, deviceName: "New-Phone"))
        XCTAssertEqual(
            SyncRuleEngine.subscribedKeys(document: document, deviceName: "New-Phone"),
            ["images", "work", "desktop only"]
        )
        XCTAssertFalse(SyncRuleEngine.isDeviceListed(document: document, deviceName: "New-Phone"))
        XCTAssertTrue(SyncRuleEngine.isDeviceListed(document: document, deviceName: "jeff-iphone"))
    }

    func testDisabledDocumentSubscribesToNothingBeyondCore() {
        var disabled = routingDocument()
        disabled.Enabled = false
        XCTAssertNil(SyncRuleEngine.subscribedChannels(document: disabled, deviceName: "Desktop"))
        XCTAssertEqual(SyncRuleEngine.subscribedKeys(document: disabled, deviceName: "Desktop"), [])
    }

    func testValidateRejectsMixedWildcardDeviceChannels() {
        var mixed = routingDocument()
        mixed.Devices = [SyncDevice(Name: "Desktop", Channels: ["*", "work"])]
        XCTAssertNotNil(SyncRuleEngine.validate(mixed))

        var unknownReference = routingDocument()
        unknownReference.Devices = [SyncDevice(Name: "Desktop", Channels: ["archive"])]
        XCTAssertNotNil(SyncRuleEngine.validate(unknownReference))
    }

    // MARK: - Merge (section 4)

    func testMergeIsWholeDocumentLastWriterWins() {
        var local = routingDocument()
        local.UpdatedUnixMs = 100
        local.UpdatedBy = "Desktop"
        var remote = routingDocument()
        remote.UpdatedUnixMs = 200
        remote.UpdatedBy = "Aardvark"

        XCTAssertEqual(SyncRuleEngine.merge(local: local, remote: remote)?.UpdatedBy, "Aardvark")
        XCTAssertEqual(SyncRuleEngine.merge(local: remote, remote: local)?.UpdatedBy, "Aardvark")
    }

    func testMergeBreaksTiesOnOrdinalUpdatedBy() {
        var local = routingDocument()
        local.UpdatedUnixMs = 100
        local.UpdatedBy = "Desktop"
        var remote = routingDocument()
        remote.UpdatedUnixMs = 100
        remote.UpdatedBy = "Work-PC"

        XCTAssertEqual(SyncRuleEngine.merge(local: local, remote: remote)?.UpdatedBy, "Work-PC")
        XCTAssertEqual(SyncRuleEngine.merge(local: remote, remote: local)?.UpdatedBy, "Work-PC")

        var lowercase = routingDocument()
        lowercase.UpdatedUnixMs = 100
        lowercase.UpdatedBy = "aardvark"
        // Ordinal comparison, not case-insensitive: "aardvark" > "Desktop".
        XCTAssertEqual(SyncRuleEngine.merge(local: local, remote: lowercase)?.UpdatedBy, "aardvark")
    }

    func testMergeHandlesNilDocuments() {
        let document = routingDocument()
        XCTAssertEqual(SyncRuleEngine.merge(local: nil, remote: document), document)
        XCTAssertEqual(SyncRuleEngine.merge(local: document, remote: nil), document)
        XCTAssertNil(SyncRuleEngine.merge(local: nil, remote: nil))
    }

    // MARK: - Encoding

    func testDocumentSurvivesCodableRoundTrip() throws {
        let document = routingDocument()
        let data = try XCTUnwrap(SyncRuleEngine.serialize(document))
        let decoded = try XCTUnwrap(SyncRuleEngine.parse(data))
        XCTAssertEqual(decoded, document)

        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"Clipman\":\"sync-rules\""))
        // Empty route conditions are omitted, matching the reference encoder.
        XCTAssertFalse(text.contains("\"Groups\":[]"))
        XCTAssertFalse(text.contains("\"SourceDevices\":[]"))
    }

    func testDecodingToleratesMissingFields() throws {
        let json = Data("{\"Clipman\":\"sync-rules\"}".utf8)
        let decoded = try XCTUnwrap(SyncRuleEngine.parse(json))
        XCTAssertEqual(decoded.Version, 1)
        XCTAssertFalse(decoded.Enabled)
        XCTAssertTrue(decoded.Channels.isEmpty)
        XCTAssertTrue(decoded.Devices.isEmpty)
    }

    // MARK: - Future versions (section 4)

    func testFutureVersionDocumentIsReadOnlyAndAcceptedLeniently() throws {
        let json = Data("""
        {"Clipman":"sync-rules","Version":7,"Enabled":true,"UpdatedUnixMs":5,"UpdatedBy":"Desktop",
         "Channels":[{"Name":"-not a key-","Route":{}},{"Name":"Work","Route":{"Groups":["Work"]}}],
         "Devices":[{"Name":"Desktop","Channels":["*","work"]}]}
        """.utf8)
        let decoded = try XCTUnwrap(SyncRuleEngine.parse(json))
        XCTAssertTrue(SyncRuleEngine.isReadOnly(decoded))
        XCTAssertTrue(SyncRuleEngine.isUsable(decoded))
        // Strict validation would have rejected both the channel name and the
        // mixed wildcard, but a future document must still be applied.
        XCTAssertNotNil(SyncRuleEngine.validate(decoded))
        XCTAssertEqual(SyncRuleEngine.allChannelKeys(decoded), ["work"])
        XCTAssertEqual(
            SyncRuleEngine.route(document: decoded, entry: ClipEntry(Text: "a", Group: "Work")),
            "work"
        )
    }

    func testCurrentVersionDocumentIsNotReadOnly() {
        XCTAssertFalse(SyncRuleEngine.isReadOnly(routingDocument()))
        XCTAssertFalse(SyncRuleEngine.isReadOnly(nil))
    }

    // MARK: - Cross-channel assembly (section 5)

    func testViewAssemblyResolvesIdCollisionByModifiedTimestamp() {
        let core = ClipDatabase(Entries: [entry(id: "a", text: "old", modified: 10)])
        let work = ClipDatabase(Entries: [entry(id: "a", text: "new", modified: 20)])
        let result = SyncChannelAssembler.buildView([
            SyncChannelSnapshot(key: "", database: core),
            SyncChannelSnapshot(key: "work", database: work)
        ])
        XCTAssertEqual(result.view.Entries.map(\.Text), ["new"])
        XCTAssertEqual(result.residence["a"], "work")
    }

    func testViewAssemblyBreaksIdCollisionTiesTowardTheEarlierChannel() {
        let core = ClipDatabase(Entries: [entry(id: "a", text: "core", modified: 10)])
        let work = ClipDatabase(Entries: [entry(id: "a", text: "work", modified: 10)])
        let result = SyncChannelAssembler.buildView([
            SyncChannelSnapshot(key: "", database: core),
            SyncChannelSnapshot(key: "work", database: work)
        ])
        XCTAssertEqual(result.view.Entries.map(\.Text), ["core"])
        XCTAssertEqual(result.residence["a"], "")
    }

    func testViewAssemblyKeepsNewChannelEntriesAtTheEndOfManualOrder() {
        var coreFirst = entry(id: "core-first", text: "core first", modified: 1)
        coreFirst.CreatedUnixMs = 1
        coreFirst.ManualOrder = 1
        var coreSecond = entry(id: "core-second", text: "core second", modified: 2)
        coreSecond.CreatedUnixMs = 2
        coreSecond.ManualOrder = 2
        var channelNew = entry(id: "channel-new", text: "channel new", modified: 3)
        channelNew.CreatedUnixMs = 3
        channelNew.ManualOrder = 1

        let result = SyncChannelAssembler.buildView([
            SyncChannelSnapshot(key: "", database: ClipDatabase(Entries: [coreFirst, coreSecond])),
            SyncChannelSnapshot(key: "work", database: ClipDatabase(Entries: [channelNew]))
        ])

        XCTAssertEqual(result.view.Entries.map(\.Id), ["core-first", "core-second", "channel-new"])
    }

    func testTextTombstoneSuppressesMatchingEntryInAnotherChannel() {
        let core = ClipDatabase(Entries: [entry(id: "a", text: "shared", modified: 10)])
        let work = ClipDatabase(DeletedEntries: [DeletedClipEntry(
            Id: "z",
            TextHash: SyncConflictResolver.textHash("shared"),
            DeletedUnixMs: TimeUtil.nowUnixMs(),
            SourceMachine: "Desktop"
        )])
        let result = SyncChannelAssembler.buildView([
            SyncChannelSnapshot(key: "", database: core),
            SyncChannelSnapshot(key: "work", database: work)
        ])
        XCTAssertTrue(result.view.Entries.isEmpty)
    }

    func testRelocationMarkerNeverSuppressesTheEntryItMoved() {
        let core = ClipDatabase(Entries: [entry(id: "a", text: "moved", modified: 10)])
        let work = ClipDatabase(DeletedEntries: [DeletedClipEntry(
            Id: "a",
            TextHash: "",
            DeletedUnixMs: TimeUtil.nowUnixMs(),
            SourceMachine: "Desktop"
        )])
        let result = SyncChannelAssembler.buildView([
            SyncChannelSnapshot(key: "", database: core),
            SyncChannelSnapshot(key: "work", database: work)
        ])
        XCTAssertEqual(result.view.Entries.map(\.Text), ["moved"])
        XCTAssertTrue(result.view.DeletedEntries.isEmpty)
    }

    func testDurableHashIgnoresTheDatabaseTimestamp() {
        var first = ClipDatabase(Entries: [entry(id: "a", text: "one", modified: 10)])
        first.UpdatedUnixMs = 1
        var second = first
        second.UpdatedUnixMs = 999_999
        XCTAssertEqual(SyncChannelAssembler.durableHash(first), SyncChannelAssembler.durableHash(second))

        var changed = first
        changed.Entries[0].Text = "two"
        XCTAssertNotEqual(SyncChannelAssembler.durableHash(first), SyncChannelAssembler.durableHash(changed))
    }

    func testPlanRelocatesEntriesAndCarriesTheFetchedCopyInPhaseOne() {
        let fetchedEntry = entry(id: "a", text: "before", modified: 10)
        var editedEntry = fetchedEntry
        editedEntry.Text = "after"
        editedEntry.Group = "Work"
        editedEntry.ModifiedUnixMs = 20

        let core = ClipDatabase(Entries: [fetchedEntry])
        let snapshots = [
            SyncChannelSnapshot(key: "", database: core),
            SyncChannelSnapshot(key: "work", database: ClipDatabase())
        ]
        let plan = SyncChannelAssembler.plan(
            entries: [editedEntry],
            document: routingDocument(),
            residence: ["a": ""],
            fetched: SyncChannelAssembler.fetchedEntries(snapshots),
            subscribed: ["", "work"],
            deviceName: "Test Phone",
            now: 30
        )
        XCTAssertEqual(plan.routed["work"]?.map(\.Text), ["after"])
        XCTAssertNil(plan.routed[""])
        XCTAssertEqual(plan.departures[""]?.map(\.Id), ["a"])
        // Phase one keeps the copy the source channel was fetched with, so the
        // source is unchanged until the target has committed the new copy.
        XCTAssertEqual(plan.withDepartures[""]?.map(\.Text), ["before"])
        XCTAssertEqual(plan.withDepartures["work"]?.map(\.Text), ["after"])
        let marker = plan.relocations[""]?.first
        XCTAssertEqual(marker?.Id, "a")
        XCTAssertEqual(marker?.TextHash, "")
        XCTAssertEqual(marker?.SourceMachine, "Test Phone")
        XCTAssertEqual(marker?.DeletedUnixMs, 30)
        XCTAssertTrue(plan.pendingKeys.isEmpty)
    }

    func testPlanParksEntriesBoundForUnsubscribedChannels() {
        var work = entry(id: "a", text: "standup notes", modified: 10)
        work.Group = "Work"
        let plan = SyncChannelAssembler.plan(
            entries: [work],
            document: routingDocument(),
            residence: [:],
            fetched: [:],
            subscribed: [""],
            deviceName: "Test Phone",
            now: 30
        )
        XCTAssertEqual(plan.pendingKeys, ["work"])
        XCTAssertEqual(plan.pending["work"]?.map(\.Id), ["a"])
        XCTAssertNil(plan.routed[""])
    }

    func testCancelDepartureKeepsTheEntryInItsSourceChannel() {
        var moving = entry(id: "a", text: "standup notes", modified: 20)
        moving.Group = "Work"
        var plan = SyncChannelAssembler.plan(
            entries: [moving],
            document: routingDocument(),
            residence: ["a": ""],
            fetched: [:],
            subscribed: [""],
            deviceName: "Test Phone",
            now: 30
        )
        XCTAssertEqual(plan.departures[""]?.count, 1)
        SyncChannelAssembler.cancelDeparture(&plan, entry: moving, source: "")
        XCTAssertEqual(plan.routed[""]?.map(\.Id), ["a"])
        XCTAssertEqual(plan.departures[""]?.isEmpty, true)
        XCTAssertEqual(plan.relocations[""]?.isEmpty, true)
    }

    func testPendingChannelWritesRoundTrip() throws {
        let pending = PendingChannelWrites.from([
            "work": [entry(id: "a", text: "one", modified: 1)],
            "images": [],
            "desktop only": [entry(id: "b", text: "two", modified: 2)]
        ])
        XCTAssertEqual(pending.Channels.map(\.ChannelKey), ["desktop only", "work"])
        let data = try JSONEncoder().encode(pending)
        let decoded = try JSONDecoder().decode(PendingChannelWrites.self, from: data)
        XCTAssertEqual(decoded, pending)
        XCTAssertEqual(decoded.byChannelKey["work"]?.map(\.Id), ["a"])
    }

    // MARK: - Helpers

    private func entry(id: String, text: String, modified: Int64) -> ClipEntry {
        ClipEntry(
            Id: id,
            Text: text,
            CreatedUnixMs: 1,
            LastUsedUnixMs: 1,
            ModifiedUnixMs: modified,
            ManualOrder: 1
        )
    }

    private func document(channels: [SyncChannel]) -> SyncRulesDocument {
        SyncRulesDocument(
            Clipman: "sync-rules",
            Version: 1,
            Enabled: true,
            UpdatedUnixMs: 1_757_200_000_000,
            UpdatedBy: "Desktop",
            Channels: channels,
            Devices: []
        )
    }

    private func routingDocument() -> SyncRulesDocument {
        SyncRulesDocument(
            Clipman: "sync-rules",
            Version: 1,
            Enabled: true,
            UpdatedUnixMs: 1_757_200_000_000,
            UpdatedBy: "Desktop",
            Channels: [
                SyncChannel(Name: "Images", Route: SyncRoute(Kind: "RichTextImages")),
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
}
