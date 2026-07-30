package me.onj.clipman

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SyncConflictResolverTest {
    @Test
    fun updateNormalizesGroupCaseToEstablishedSpelling() {
        val target = entry("target", "Target", 1).copy(Group = "")
        val history = database(
            target,
            entry("kobo-1", "One", 2).copy(Group = "Kobo", ModifiedUnixMs = 10),
            entry("kobo-2", "Two", 3).copy(Group = "Kobo", ModifiedUnixMs = 20),
            entry("typo", "Three", 4).copy(Group = "KObo", ModifiedUnixMs = 30)
        )

        val updated = SyncConflictResolver.updateEntry(history, target.copy(Group = "kObO"))

        assertEquals("Kobo", updated.Entries.first { it.Id == "target" }.Group)
    }

    @Test
    fun mergeKeepsOfflineAdditionsFromBothSides() {
        val local = database(entry("local", "Local entry", 1))
        val server = database(entry("server", "Server entry", 2))

        val merged = SyncConflictResolver.merge(local, server)

        assertEquals(setOf("Local entry", "Server entry"), merged.Entries.map { it.Text }.toSet())
    }

    @Test
    fun mergeAppliesDeletionMarkersInsteadOfResurrectingEntries() {
        val removed = entry("removed", "Remove me", 1)
        val local = database().copy(
            DeletedEntries = listOf(
                DeletedClipEntry(
                    Id = removed.Id,
                    TextHash = SyncConflictResolver.textHash(removed.Text),
                    DeletedUnixMs = 100,
                    SourceMachine = "Phone"
                )
            )
        )
        val server = database(removed, entry("kept", "Keep me", 2))

        val merged = SyncConflictResolver.merge(local, server)

        assertFalse(merged.Entries.any { it.Id == removed.Id })
        assertTrue(merged.Entries.any { it.Id == "kept" })
        assertEquals(1, merged.DeletedEntries.size)
    }

    @Test
    fun contentComparisonIgnoresDatabaseTimestampOnlyChanges() {
        val original = database(entry("one", "One", 1))
        val newerTimestamp = original.copy(UpdatedUnixMs = original.UpdatedUnixMs + 50_000)

        assertTrue(SyncConflictResolver.hasSameContent(original, newerTimestamp))
    }

    @Test
    fun sameTextEntryRecreatedAfterDeletionSurvives() {
        val text = "https://example.com/recreated"
        val marker = DeletedClipEntry("deleted-original", SyncConflictResolver.textHash(text), 100, "Desktop")
        val local = database().copy(DeletedEntries = listOf(marker))
        val server = database(entry("new-copy", text, 101))

        val merged = SyncConflictResolver.merge(local, server)

        assertTrue(merged.Entries.any { it.Id == "new-copy" })
    }

    @Test
    fun sameTextEntryOlderThanDeletionStaysDeleted() {
        val text = "https://example.com/stale"
        val marker = DeletedClipEntry("deleted-original", SyncConflictResolver.textHash(text), 100, "Desktop")
        val local = database().copy(DeletedEntries = listOf(marker))
        val server = database(entry("stale-copy", text, 99))

        val merged = SyncConflictResolver.merge(local, server)

        assertFalse(merged.Entries.any { it.Id == "stale-copy" })
    }

    @Test
    fun exactDeletedIdentityCannotBeRecreated() {
        val text = "https://example.com/deleted-id"
        val marker = DeletedClipEntry("same-id", SyncConflictResolver.textHash(text), 100, "Desktop")
        val local = database().copy(DeletedEntries = listOf(marker))
        val server = database(entry("same-id", text, 101))

        val merged = SyncConflictResolver.merge(local, server)

        assertFalse(merged.Entries.any { it.Id == "same-id" })
    }

    @Test
    fun richTextUsesIndependentTimestampAndSupportsClear() {
        val local = database(
            entry("rich", "formatted", 1).copy(
                LastUsedUnixMs = 500,
                RichText = RichTextPayload(HtmlFragment = "<b>formatted</b>", PreferredFormat = "Html"),
                RichTextUpdatedUnixMs = 100
            )
        )
        val remote = database(
            entry("rich", "formatted", 1).copy(
                LastUsedUnixMs = 200,
                RichText = null,
                RichTextUpdatedUnixMs = 300
            )
        )

        val merged = SyncConflictResolver.merge(local, remote)

        assertEquals(null, merged.Entries.first().RichText)
        assertEquals(300, merged.Entries.first().RichTextUpdatedUnixMs)
    }

    @Test
    fun addingAndroidHtmlStoresRichTextWithPlainFallback() {
        val rich = RichTextPayload(HtmlFragment = "<h1>Heading</h1>", PreferredFormat = "Html")

        val updated = SyncConflictResolver.addText(database(), "Heading", "Android", rich)

        assertEquals("Heading", updated.Entries.single().Text)
        assertEquals("<h1>Heading</h1>", updated.Entries.single().RichText?.HtmlFragment)
        assertTrue(updated.Entries.single().RichTextUpdatedUnixMs > 0)
    }

    @Test
    fun readdingPlainTextDoesNotDiscardExistingFormatting() {
        val formatted = entry("rich", "Heading", 1).copy(
            RichText = RichTextPayload(HtmlFragment = "<h1>Heading</h1>", PreferredFormat = "Html"),
            RichTextUpdatedUnixMs = 50
        )

        val updated = SyncConflictResolver.addText(database(formatted), "Heading", "Android")

        assertEquals("<h1>Heading</h1>", updated.Entries.single().RichText?.HtmlFragment)
        assertEquals(50, updated.Entries.single().RichTextUpdatedUnixMs)
    }

    @Test
    fun oversizedAndroidHtmlIsRejected() {
        val oversized = RichTextPayload(HtmlFragment = "x".repeat(768 * 1024 + 1), PreferredFormat = "Html")

        assertEquals(null, RichTextClipboard.normalize(oversized))
    }

    @Test
    fun newerModificationReplacesEditableEntryState() {
        val local = database(entry("edited", "old text", 1).copy(
            ModifiedUnixMs = 100,
            Name = "Old name",
            Group = "Old group",
            Pinned = true,
            IsTemplate = true
        ))
        val server = database(entry("edited", "new text", 1).copy(
            ModifiedUnixMs = 200,
            Name = "New name",
            Group = "New group",
            Pinned = false,
            IsTemplate = false
        ))

        val merged = SyncConflictResolver.merge(local, server).Entries.single()

        assertEquals("new text", merged.Text)
        assertEquals("New name", merged.Name)
        assertEquals("New group", merged.Group)
        assertFalse(merged.Pinned)
        assertFalse(merged.IsTemplate)
        assertEquals(200, merged.ModifiedUnixMs)
    }

    @Test
    fun olderModificationCannotOverwriteNewerEdit() {
        val local = database(entry("edited", "new text", 1).copy(ModifiedUnixMs = 200))
        val server = database(entry("edited", "old text", 1).copy(ModifiedUnixMs = 100))

        val merged = SyncConflictResolver.merge(local, server).Entries.single()

        assertEquals("new text", merged.Text)
        assertEquals(200, merged.ModifiedUnixMs)
    }

    @Test
    fun legacySameIdentityRepairsTextFromServer() {
        val local = database(entry("legacy", "stale text", 1))
        val server = database(entry("legacy", "edited text", 1))

        val merged = SyncConflictResolver.merge(local, server).Entries.single()

        assertEquals("edited text", merged.Text)
    }

    private fun database(vararg entries: ClipEntry) = ClipDatabase(
        Version = 1,
        UpdatedUnixMs = 10,
        Entries = entries.toList(),
        DeletedEntries = emptyList()
    )

    private fun entry(id: String, text: String, order: Long) = ClipEntry(
        Id = id,
        Text = text,
        SourceMachine = "Test",
        CreatedUnixMs = order,
        LastUsedUnixMs = order,
        ManualOrder = order
    )
}
