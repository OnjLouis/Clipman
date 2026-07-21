package me.onj.clipman

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SyncConflictResolverTest {
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
