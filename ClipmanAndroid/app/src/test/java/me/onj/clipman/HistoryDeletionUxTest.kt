package me.onj.clipman

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class HistoryDeletionUxTest {
    @Test
    fun deletionIsAnOptimisticLocalMutationWithATombstone() {
        val target = entry("remove", "Remove me", 1)
        val retained = entry("keep", "Keep me", 2)
        val original = database(target, retained)

        val optimistic = SyncConflictResolver.deleteEntry(original, target.Id)

        assertTrue(original.Entries.any { it.Id == target.Id })
        assertFalse(optimistic.Entries.any { it.Id == target.Id })
        assertTrue(optimistic.Entries.any { it.Id == retained.Id })
        assertTrue(optimistic.DeletedEntries.any { it.Id == target.Id })
    }

    @Test
    fun localWriteFailurePrefersReloadedDurableHistory() {
        val previous = database(entry("previous", "Previous", 1))
        val reloaded = database(entry("disk", "From disk", 2))

        assertSame(reloaded, recoverHistoryAfterLocalWriteFailure(previous, reloaded))
    }

    @Test
    fun localWriteFailureFallsBackToPreChangeSnapshot() {
        val previous = database(entry("previous", "Previous", 1))

        assertSame(previous, recoverHistoryAfterLocalWriteFailure(previous, null))
    }

    @Test
    fun failureMessagesDistinguishRollbackFromPendingServerSync() {
        val error = IllegalStateException("disk unavailable")

        assertEquals(
            "Deleting entry could not be saved. History was restored: disk unavailable",
            localHistoryWriteFailureStatus("Deleting entry", error)
        )
        assertEquals(
            "Deleting entry saved locally; server sync is pending: disk unavailable",
            remoteHistoryWriteFailureStatus("Deleting entry", error)
        )
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
