package me.onj.clipman

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CloudHistoryBackupTest {
    @Test
    fun encryptedBackupRoundTripsAndMergesWithoutReplacingNewerHistory() {
        val password = "backup test password"
        val backup = ClipDatabase(
            Entries = mutableListOf(
                ClipEntry(Id = "from-backup", Text = "Backup entry", CreatedUnixMs = 100, ModifiedUnixMs = 100)
            )
        )
        val encoded = ClipDatabaseFile.save(backup, password)

        assertTrue(ClipDatabaseFile.isEncrypted(encoded))
        val restored = ClipDatabaseFile.load(encoded, password)
        val current = ClipDatabase(
            Entries = mutableListOf(
                ClipEntry(Id = "current", Text = "Current entry", CreatedUnixMs = 200, ModifiedUnixMs = 200)
            )
        )
        val merged = SyncConflictResolver.merge(target = current, source = restored)

        assertEquals(setOf("current", "from-backup"), merged.Entries.map { it.Id }.toSet())
    }

    @Test
    fun unencryptedHistoryIsNotAcceptedAsACloudBackup() {
        val encoded = ClipDatabaseFile.save(ClipDatabase(), "")
        assertFalse(ClipDatabaseFile.isEncrypted(encoded))
    }
}
