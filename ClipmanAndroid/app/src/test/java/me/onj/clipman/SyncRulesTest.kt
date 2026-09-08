package me.onj.clipman

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The cross-client contract of sync-rules-spec.md sections 2 to 4. Every
 * expectation here is shared with ClipmanCli/internal/rules and the Windows
 * client, so a change that breaks one of these breaks the fleet.
 */
class SyncRulesTest {
    private val exampleToken = "example-token"
    private val examplePassword = "example-password"

    // -- Section 2: bucket identity ---------------------------------------

    @Test
    fun databaseIdMatchesTheExistingCrossClientVector() {
        assertEquals(
            "l4GLcFU7RrlmkGXoRyQ7-zVG5D5S0VmfwO6-dGNmebU",
            ServerDatabaseIdentity.fromTokenAndPassword(exampleToken, examplePassword)
        )
    }

    @Test
    fun syncRulesIdMatchesTheCrossClientVector() {
        assertEquals(
            "j5Z6kOIWgsJMqS0IRzNJEq38aqJ-iA8e6yzyX0W71WQ",
            ServerDatabaseIdentity.syncRulesId(exampleToken, examplePassword)
        )
    }

    @Test
    fun channelIdsMatchTheCrossClientVectors() {
        assertEquals(
            "F0MZBlui50Vd37JVf-JcvOWvoHV71IDlQE5OnfVBKeA",
            ServerDatabaseIdentity.channelId(exampleToken, examplePassword, "work")
        )
        assertEquals(
            "K_hH97mxfF4_DQvN90Orzu_HUz7MOcKYoL3-6nY-TbQ",
            ServerDatabaseIdentity.channelId(exampleToken, examplePassword, "images")
        )
        assertEquals(
            "02tgOt5QC_sWY2RmoI2pqII9MocLQ7-XIMHaSRVBE1o",
            ServerDatabaseIdentity.channelId(exampleToken, examplePassword, "desktop only")
        )
    }

    @Test
    fun channelIdsNormalizeTheirKeyAndRequireCredentials() {
        assertEquals(
            ServerDatabaseIdentity.channelId(exampleToken, examplePassword, "work"),
            ServerDatabaseIdentity.channelId(exampleToken, examplePassword, "  WORK  ")
        )
        assertEquals("", ServerDatabaseIdentity.channelId(exampleToken, examplePassword, "-nope-"))
        assertEquals("", ServerDatabaseIdentity.channelId("", examplePassword, "work"))
        assertEquals("", ServerDatabaseIdentity.channelId(exampleToken, "", "work"))
        assertEquals("", ServerDatabaseIdentity.syncRulesId(exampleToken, ""))
    }

    // -- Section 3: channel keys ------------------------------------------

    @Test
    fun channelKeyGrammarAcceptsOnlyLegalNames() {
        assertEquals("work", SyncRuleEngine.channelKey("Work"))
        assertEquals("work", SyncRuleEngine.channelKey("  WoRk "))
        assertEquals("desktop only", SyncRuleEngine.channelKey("Desktop Only"))
        assertEquals("a-b_c 1", SyncRuleEngine.channelKey("A-B_C 1"))
        assertEquals("a", SyncRuleEngine.channelKey("a"))
        assertEquals("a".repeat(32), SyncRuleEngine.channelKey("A".repeat(32)))

        assertEquals("", SyncRuleEngine.channelKey(""))
        assertEquals("", SyncRuleEngine.channelKey("   "))
        assertEquals("", SyncRuleEngine.channelKey("-work"))
        assertEquals("", SyncRuleEngine.channelKey("work-"))
        assertEquals("", SyncRuleEngine.channelKey("_work"))
        assertEquals("", SyncRuleEngine.channelKey("work_"))
        assertEquals("", SyncRuleEngine.channelKey("a".repeat(33)))
        assertEquals("", SyncRuleEngine.channelKey("Arbeitä"))
        assertEquals("", SyncRuleEngine.channelKey("work/images"))
    }

    @Test
    fun channelStorageNameReplacesSpacesWithDashes() {
        assertEquals("desktop-only", SyncRuleEngine.channelStorageName("desktop only"))
        assertEquals("work", SyncRuleEngine.channelStorageName("work"))
    }

    // -- Section 4: validation --------------------------------------------

    private fun channel(name: String, route: SyncRoute) = SyncChannel(Name = name, Route = route)

    private fun document(
        channels: List<SyncChannel> = emptyList(),
        devices: List<SyncDevice> = emptyList(),
        enabled: Boolean = true,
        version: Int = 1
    ) = SyncRulesDocument(
        Version = version,
        Enabled = enabled,
        UpdatedUnixMs = 1_757_200_000_000L,
        UpdatedBy = "Desktop",
        Channels = channels,
        Devices = devices
    )

    @Test
    fun validationRejectsReservedDuplicateAndUnroutableChannels() {
        assertNull(validationError(document(listOf(channel("Work", SyncRoute(Groups = listOf("Work")))))))

        assertNotNull(validationError(document(listOf(channel("Core", SyncRoute(Groups = listOf("Work")))))))
        assertNotNull(validationError(document(listOf(channel("Pinned", SyncRoute(Groups = listOf("Work")))))))
        assertNotNull(validationError(document(listOf(channel("sync-rules", SyncRoute(Groups = listOf("Work")))))))
        assertNotNull(
            validationError(
                document(
                    listOf(
                        channel("Work", SyncRoute(Groups = listOf("Work"))),
                        channel("WORK", SyncRoute(Groups = listOf("Other")))
                    )
                )
            )
        )
        assertNotNull(validationError(document(listOf(channel("-nope-", SyncRoute(Groups = listOf("Work")))))))
        assertNotNull(validationError(document(listOf(channel("Work", SyncRoute())))))
        assertNotNull(validationError(document(listOf(channel("Work", SyncRoute(Kind = "Screenshots"))))))
    }

    @Test
    fun validationRejectsChannelsThatWouldShareAStorageFile() {
        assertNotNull(
            validationError(
                document(
                    listOf(
                        channel("Desk top", SyncRoute(Groups = listOf("A"))),
                        channel("Desk-top", SyncRoute(Groups = listOf("B")))
                    )
                )
            )
        )
    }

    @Test
    fun validationRejectsMixedStarAndUnknownChannelReferences() {
        val channels = listOf(channel("Work", SyncRoute(Groups = listOf("Work"))))
        assertNotNull(
            validationError(document(channels, listOf(SyncDevice("Phone", listOf("*", "work")))))
        )
        assertNotNull(
            validationError(document(channels, listOf(SyncDevice("Phone", listOf("images")))))
        )
        assertNull(validationError(document(channels, listOf(SyncDevice("Phone", listOf("*"))))))
        assertNull(validationError(document(channels, listOf(SyncDevice("Phone", listOf("WORK"))))))
    }

    private fun validationError(document: SyncRulesDocument): String? = SyncRuleEngine.validate(document)

    // -- Section 4: routing -----------------------------------------------

    private fun entry(
        id: String,
        text: String = "text-$id",
        group: String = "",
        sourceMachine: String = "",
        html: String? = null
    ) = ClipEntry(
        Id = id,
        Text = text,
        Group = group,
        SourceMachine = sourceMachine,
        CreatedUnixMs = 1_700_000_000_000L,
        LastUsedUnixMs = 1_700_000_000_000L,
        ModifiedUnixMs = 1_700_000_000_000L,
        ManualOrder = 1,
        RichText = html?.let { RichTextPayload(HtmlFragment = it) }
    )

    private val routingDocument = document(
        channels = listOf(
            channel("Images", SyncRoute(Kind = SyncRuleEngine.richTextImagesKind)),
            channel("Work", SyncRoute(Groups = listOf("Work", "Standup"))),
            channel("Desktop only", SyncRoute(SourceDevices = listOf("Desktop", "Work-PC"))),
            channel(
                "Both",
                SyncRoute(Groups = listOf("Shared"), SourceDevices = listOf("Laptop"))
            )
        )
    )

    @Test
    fun routingUsesTheFirstMatchingChannelAndFallsBackToCore() {
        assertEquals("work", SyncRuleEngine.routeEntry(routingDocument, entry("1", group = "work")))
        assertEquals("work", SyncRuleEngine.routeEntry(routingDocument, entry("2", group = " STANDUP ")))
        assertEquals(
            "desktop only",
            SyncRuleEngine.routeEntry(routingDocument, entry("3", sourceMachine = "desktop"))
        )
        assertEquals("", SyncRuleEngine.routeEntry(routingDocument, entry("4")))
        // Work is listed before Desktop only, so a Work entry from Desktop
        // still lands in work.
        assertEquals(
            "work",
            SyncRuleEngine.routeEntry(routingDocument, entry("5", group = "Work", sourceMachine = "Desktop"))
        )
    }

    @Test
    fun routeConditionsAreAndedTogether() {
        assertEquals(
            "both",
            SyncRuleEngine.routeEntry(
                routingDocument,
                entry("6", group = "Shared", sourceMachine = "Laptop")
            )
        )
        assertEquals(
            "",
            SyncRuleEngine.routeEntry(routingDocument, entry("7", group = "Shared", sourceMachine = "Phone"))
        )
        assertEquals(
            "",
            SyncRuleEngine.routeEntry(routingDocument, entry("8", group = "Other", sourceMachine = "Laptop"))
        )
    }

    @Test
    fun richTextImagesMatchesOnlyEmbeddedImageMarkup() {
        assertEquals(
            "images",
            SyncRuleEngine.routeEntry(
                routingDocument,
                entry("9", html = "<p><img src=\"data:image/png;base64,AAA\"></p>")
            )
        )
        assertEquals(
            "",
            SyncRuleEngine.routeEntry(routingDocument, entry("10", html = "<p>plain formatted text</p>"))
        )
        assertEquals("", SyncRuleEngine.routeEntry(routingDocument, entry("11")))
    }

    @Test
    fun disabledRulesRouteEverythingToCore() {
        val disabled = routingDocument.copy(Enabled = false)
        assertEquals("", SyncRuleEngine.routeEntry(disabled, entry("12", group = "Work")))
        assertEquals("", SyncRuleEngine.routeEntry(null, entry("13", group = "Work")))
    }

    @Test
    fun unknownRouteKindNeverMatches() {
        // A future-version document is applied leniently, so an unrecognized
        // Kind must simply never match instead of routing everything into it.
        val future = document(
            channels = listOf(
                channel("Screens", SyncRoute(Kind = "Screenshots")),
                channel("Work", SyncRoute(Groups = listOf("Work")))
            ),
            version = 2
        )
        assertTrue(SyncRuleEngine.isReadOnly(future))
        assertEquals("", SyncRuleEngine.routeEntry(future, entry("14", html = "<img src=\"data:image/png;base64,A\">")))
        assertEquals("work", SyncRuleEngine.routeEntry(future, entry("15", group = "Work")))
    }

    @Test
    fun channelsWithUnusableNamesAreSkippedNotRoutedToCore() {
        val future = document(
            channels = listOf(
                channel("-broken-", SyncRoute(Groups = listOf("Work"))),
                channel("Work", SyncRoute(Groups = listOf("Work")))
            ),
            version = 2
        )
        assertEquals("work", SyncRuleEngine.routeEntry(future, entry("16", group = "Work")))
    }

    // -- Section 4: subscriptions -----------------------------------------

    private val subscriptionDocument = document(
        channels = listOf(
            channel("Images", SyncRoute(Kind = SyncRuleEngine.richTextImagesKind)),
            channel("Work", SyncRoute(Groups = listOf("Work"))),
            channel("Desktop only", SyncRoute(SourceDevices = listOf("Desktop")))
        ),
        devices = listOf(
            SyncDevice("Desktop", listOf("*")),
            SyncDevice("Jeff-iPhone", listOf("work")),
            SyncDevice("Work-PC", listOf("desktop only", "work"))
        )
    )

    @Test
    fun subscriptionsResolvePerDevice() {
        assertEquals(
            listOf("images", "work", "desktop only"),
            SyncRuleEngine.subscribedChannels(subscriptionDocument, "Desktop")
        )
        assertEquals(listOf("work"), SyncRuleEngine.subscribedChannels(subscriptionDocument, " jeff-iphone "))
        assertEquals(
            listOf("desktop only", "work"),
            SyncRuleEngine.subscribedChannels(subscriptionDocument, "Work-PC")
        )
        // An unlisted device subscribes to everything, which is expressed as null.
        assertNull(SyncRuleEngine.subscribedChannels(subscriptionDocument, "Unknown-Tablet"))
        assertNull(SyncRuleEngine.subscribedChannels(subscriptionDocument.copy(Enabled = false), "Desktop"))
    }

    @Test
    fun subscribedKeysStayInDocumentOrderAndDefaultToEverything() {
        assertEquals(
            listOf("images", "work", "desktop only"),
            SyncRuleEngine.subscribedKeys(subscriptionDocument, "Unknown-Tablet")
        )
        assertEquals(listOf("work"), SyncRuleEngine.subscribedKeys(subscriptionDocument, "Jeff-iPhone"))
        // Document order, not the order the device happened to list them in.
        assertEquals(
            listOf("work", "desktop only"),
            SyncRuleEngine.subscribedKeys(subscriptionDocument, "Work-PC")
        )
        assertEquals(emptyList<String>(), SyncRuleEngine.subscribedKeys(null, "Desktop"))
    }

    @Test
    fun deviceRegistrationHelpersDescribeThisDevice() {
        assertTrue(SyncRuleEngine.isRegistered(subscriptionDocument, "jeff-iphone"))
        assertFalse(SyncRuleEngine.isRegistered(subscriptionDocument, "Unknown-Tablet"))
        assertTrue(SyncRuleEngine.subscribesToAllChannels(subscriptionDocument, "Desktop"))
        assertFalse(SyncRuleEngine.subscribesToAllChannels(subscriptionDocument, "Jeff-iPhone"))
        assertTrue(SyncRuleEngine.subscribesToAllChannels(subscriptionDocument, "Unknown-Tablet"))
    }

    @Test
    fun deviceSubscriptionEditsReplaceOnlyThatDevice() {
        val updated = SyncRuleEngine.withDeviceSubscription(
            subscriptionDocument,
            "Jeff-iPhone",
            listOf("Work", "images"),
            1_800_000_000_000L
        )
        assertEquals(listOf("images", "work"), SyncRuleEngine.subscribedKeys(updated, "Jeff-iPhone"))
        assertEquals(3, updated.Devices.size)
        assertEquals(1_800_000_000_000L, updated.UpdatedUnixMs)
        assertEquals("Jeff-iPhone", updated.UpdatedBy)
        assertNull(SyncRuleEngine.validate(updated))

        val registered = SyncRuleEngine.withDeviceSubscription(
            subscriptionDocument,
            "New-Phone",
            null,
            1_800_000_000_000L
        )
        assertEquals(4, registered.Devices.size)
        assertTrue(SyncRuleEngine.subscribesToAllChannels(registered, "New-Phone"))
        assertNull(SyncRuleEngine.validate(registered))
    }

    // -- Section 4: merge --------------------------------------------------

    @Test
    fun documentsMergeByLastWriterWins() {
        val older = document().copy(UpdatedUnixMs = 100, UpdatedBy = "Desktop")
        val newer = document().copy(UpdatedUnixMs = 200, UpdatedBy = "Android")

        assertTrue(SyncRuleEngine.mergeDocuments(older, newer) === newer)
        assertTrue(SyncRuleEngine.mergeDocuments(newer, older) === newer)
    }

    @Test
    fun mergeTiesBreakTowardTheGreaterUpdatedByOrdinal() {
        val local = document().copy(UpdatedUnixMs = 100, UpdatedBy = "Android")
        val remote = document().copy(UpdatedUnixMs = 100, UpdatedBy = "Desktop")

        assertTrue(SyncRuleEngine.mergeDocuments(local, remote) === remote)
        assertTrue(SyncRuleEngine.mergeDocuments(remote, local) === remote)
    }

    @Test
    fun mergeHandlesMissingDocuments() {
        val only = document()
        assertTrue(SyncRuleEngine.mergeDocuments(null, only) === only)
        assertTrue(SyncRuleEngine.mergeDocuments(only, null) === only)
        assertNull(SyncRuleEngine.mergeDocuments(null, null))
    }

    // -- Section 4: encoding -----------------------------------------------

    private val specExample = """
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
    """.trimIndent()

    @Test
    fun theSpecExampleDocumentParses() {
        val document = SyncRuleEngine.parse(specExample)
        assertNotNull(document)
        requireNotNull(document)
        assertTrue(document.Enabled)
        assertEquals(1_757_200_000_000L, document.UpdatedUnixMs)
        assertEquals("Desktop", document.UpdatedBy)
        assertEquals(listOf("images", "work", "desktop only"), SyncRuleEngine.allChannelKeys(document))
        assertEquals(listOf("work"), SyncRuleEngine.subscribedKeys(document, "Jeff-iPhone"))
        assertEquals(
            SyncRuleEngine.richTextImagesKind,
            document.Channels[0].Route.Kind
        )
        assertEquals(listOf("Work", "Standup"), document.Channels[1].Route.Groups)
        assertEquals(listOf("Desktop", "Work-PC"), document.Channels[2].Route.SourceDevices)
    }

    @Test
    fun documentsRoundTripThroughJson() {
        val original = requireNotNull(SyncRuleEngine.parse(specExample))
        val encoded = SyncRuleEngine.serialize(original)

        assertTrue(encoded.contains("\"Clipman\":\"sync-rules\""))
        assertTrue(encoded.contains("\"SourceDevices\""))
        assertEquals(original, SyncRuleEngine.parse(encoded))
    }

    @Test
    fun documentsWithTheWrongMarkerAreRejected() {
        assertNull(SyncRuleEngine.parse(specExample.replace("sync-rules", "clip-rules")))
        assertNull(SyncRuleEngine.parse("not json at all"))
        assertNull(
            SyncRuleEngine.parse(
                """{"Clipman":"sync-rules","Version":1,"Enabled":true,"Channels":[{"Name":"Core","Route":{"Groups":["A"]}}]}"""
            )
        )
    }

    @Test
    fun futureVersionDocumentsAreAppliedButNeverRewritten() {
        // Version 2 with a channel this client cannot validate: it is accepted
        // read-only rather than rejected, and what it does understand applies.
        val payload = """
            {
              "Clipman": "sync-rules",
              "Version": 2,
              "Enabled": true,
              "UpdatedUnixMs": 10,
              "UpdatedBy": "Desktop",
              "Channels": [
                { "Name": "Screens", "Route": { "Kind": "Screenshots" } },
                { "Name": "Work",    "Route": { "Groups": ["Work"] } }
              ],
              "Devices": [ { "Name": "Android Pixel", "Channels": ["work"] } ]
            }
        """.trimIndent()

        val document = requireNotNull(SyncRuleEngine.parse(payload))
        assertTrue(SyncRuleEngine.isReadOnly(document))
        assertNotNull(SyncRuleEngine.validate(document))
        assertEquals(listOf("work"), SyncRuleEngine.subscribedKeys(document, "Android Pixel"))
        assertEquals("work", SyncRuleEngine.routeEntry(document, entry("17", group = "Work")))
    }

    @Test
    fun aRouteThatIsAbsentOrNullDecodesToNoConditions() {
        val document = requireNotNull(
            SyncRuleEngine.parse(
                """
                {
                  "Clipman": "sync-rules",
                  "Version": 2,
                  "Enabled": true,
                  "Channels": [ { "Name": "Empty" }, { "Name": "Nulled", "Route": null } ],
                  "Devices": null
                }
                """.trimIndent()
            )
        )
        assertEquals("", SyncRuleEngine.routeEntry(document, entry("18", group = "Work")))
        assertEquals(emptyList<SyncDevice>(), document.Devices)
    }

    // -- Section 5: durable dirty hash -------------------------------------

    @Test
    fun durablePlainHashIgnoresTheDatabaseUpdatedStamp() {
        val database = ClipDatabase(
            Version = 1,
            UpdatedUnixMs = 111,
            Entries = listOf(entry("a"), entry("b"))
        )

        assertEquals(
            SyncRuleEngine.durablePlainHash(database),
            SyncRuleEngine.durablePlainHash(database.copy(UpdatedUnixMs = 999))
        )
        assertFalse(
            SyncRuleEngine.durablePlainHash(database) ==
                SyncRuleEngine.durablePlainHash(database.copy(Entries = listOf(entry("a"))))
        )
        assertEquals(64, SyncRuleEngine.durablePlainHash(database).length)
    }

    @Test
    fun pendingChannelWritesRoundTrip() {
        val pending = PendingChannelWrites(
            listOf(PendingChannelWrite("work", listOf(entry("a"), entry("b"))))
        )

        assertEquals(
            pending,
            SyncRuleEngine.parsePendingWrites(SyncRuleEngine.serializePendingWrites(pending))
        )
        assertEquals(PendingChannelWrites(), SyncRuleEngine.parsePendingWrites("broken"))
    }
}
