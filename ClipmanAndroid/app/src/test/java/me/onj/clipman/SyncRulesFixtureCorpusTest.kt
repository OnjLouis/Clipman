package me.onj.clipman

import java.io.File
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeNotNull
import org.junit.Test

/**
 * Task 6.1 of the sync rules plan: decode the interoperability blobs the Go
 * reference implementation generated under ClipmanCli/testdata/fixtures/go/,
 * apply this client's own subscription and merge logic for device Jeff-iPhone
 * (subscribed to the work channel only), and compare the assembled view
 * against expected-view.json. A failure here is a real cross-device sync
 * break, not a style disagreement.
 */
class SyncRulesFixtureCorpusTest {
    private val password = "example-password"
    private val json = Json { ignoreUnknownKeys = true }

    /** The reduced expectation shape recorded in the corpus (ClipmanCli/testdata/fixtures/README.md). */
    @Serializable
    private data class FixtureViewEntry(
        val id: String = "",
        val text: String = "",
        val name: String = "",
        val group: String = "",
        val sourceMachine: String = "",
        val createdUnixMs: Long = 0,
        val lastUsedUnixMs: Long = 0,
        val pinned: Boolean = false,
        val isTemplate: Boolean = false,
        val manualOrder: Long = 0,
        val hasRichText: Boolean = false
    )

    @Serializable
    private data class FixtureDeleted(val id: String = "")

    @Serializable
    private data class FixtureExpectedView(
        val version: Int = 0,
        val updatedUnixMs: Long = 0,
        val entries: List<FixtureViewEntry> = emptyList(),
        val deleted: List<FixtureDeleted> = emptyList()
    )

    /**
     * The corpus lives in the sibling ClipmanCli tree. Unit tests run from the
     * app module directory, so the lookup walks upward until it finds the
     * repository layout; a checkout without the corpus skips rather than fails.
     */
    private fun corpusDirectory(): File? {
        var probe: File? = File(".").absoluteFile
        while (probe != null) {
            val candidate = File(probe, "ClipmanCli/testdata/fixtures/go")
            if (candidate.isDirectory) return candidate
            probe = probe.parentFile
        }
        return null
    }

    @Test
    fun goSyncRulesFixtureCorpusDecodesIntoTheExpectedView() {
        val directory = corpusDirectory()
        assumeNotNull(directory)
        directory!!

        val rulesPayload = ClipDatabaseFile.loadRawText(File(directory, "sync-rules.clipdb").readBytes(), password)
        val document = SyncRuleEngine.parse(rulesPayload)
        assertNotNull("the rules blob did not parse into a sync-rules document", document)
        assertTrue(document!!.Enabled)
        assertNull(SyncRuleEngine.validate(document))
        assertEquals(listOf("work"), SyncRuleEngine.subscribedChannels(document, "Jeff-iPhone"))

        val core = ClipDatabaseFile.load(File(directory, "core.clipdb").readBytes(), password)
        val work = ClipDatabaseFile.load(File(directory, "channel-work.clipdb").readBytes(), password)
        val images = ClipDatabaseFile.load(File(directory, "channel-images.clipdb").readBytes(), password)
        assertTrue(core.Entries.isNotEmpty())
        assertTrue(work.Entries.isNotEmpty())
        assertTrue(images.Entries.isNotEmpty())

        // Assemble the subscribed view through the channel engine used by the
        // application. A plain database merge cannot reproduce channel-local
        // manual order because it discards the owner of each entry.
        val view = MobileChannelEngine.buildView(
            listOf(
                MobileChannelState(key = "", database = core),
                MobileChannelState(key = "work", database = work)
            )
        ).view

        val expected = json.decodeFromString<FixtureExpectedView>(
            File(directory, "expected-view.json").readText(Charsets.UTF_8)
        )

        val actual = view.Entries.sortedBy { it.Id }
        assertEquals("view entry count", expected.entries.size, actual.size)
        actual.zip(expected.entries).forEach { (got, want) ->
            assertEquals(want.id, got.Id)
            assertEquals("entry ${want.id} text", want.text, got.Text)
            assertEquals("entry ${want.id} name", want.name, got.Name)
            assertEquals("entry ${want.id} group", want.group, got.Group)
            assertEquals("entry ${want.id} source device", want.sourceMachine, got.SourceMachine)
            assertEquals("entry ${want.id} created", want.createdUnixMs, got.CreatedUnixMs)
            assertEquals("entry ${want.id} last used", want.lastUsedUnixMs, got.LastUsedUnixMs)
            assertEquals("entry ${want.id} pinned", want.pinned, got.Pinned)
            assertEquals("entry ${want.id} template", want.isTemplate, got.IsTemplate)
            assertEquals("entry ${want.id} manual order", want.manualOrder, got.ManualOrder)
            assertEquals("entry ${want.id} rich text presence", want.hasRichText, got.RichText != null)
        }
        assertEquals("view tombstone count", expected.deleted.size, view.DeletedEntries.size)

        // The images channel is unsubscribed: none of its entries may appear.
        images.Entries.forEach { entry ->
            assertFalse(
                "an unsubscribed channel's entry leaked into the view",
                view.Entries.any { it.Id.equals(entry.Id, ignoreCase = true) }
            )
        }
    }
}
