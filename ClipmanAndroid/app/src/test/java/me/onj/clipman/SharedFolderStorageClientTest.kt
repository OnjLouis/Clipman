package me.onj.clipman

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class SharedFolderStorageClientTest {
    private val password = "shared-folder-test-password"

    @Test
    fun firstWriteRoundTripsEncryptedHistory() {
        val backend = FakeSharedFolderBackend()
        val client = SharedFolderStorageClient(backend, password)
        val database = ClipDatabase(Entries = listOf(ClipEntry(Id = "one", Text = "First device")))
        val encoded = ClipDatabaseFile.save(database, password)

        val uploaded = client.upload(encoded, "", createOnly = true)
        val downloaded = client.download()

        assertTrue(uploaded.revision.isNotBlank())
        assertEquals(uploaded.revision, downloaded.revision)
        assertEquals(database, ClipDatabaseFile.load(downloaded.data, password))
        assertTrue(ClipDatabaseFile.isEncrypted(backend.files.getValue(LocalHistoryStore.coreFileName)))
    }

    @Test
    fun staleRevisionCannotOverwriteAnotherDevice() {
        val backend = FakeSharedFolderBackend()
        val first = SharedFolderStorageClient(backend, password)
        val second = SharedFolderStorageClient(backend, password)
        first.upload(encoded("one", "First"), "", createOnly = true)
        val staleRevision = second.metadata()
        first.upload(encoded("two", "Second"), first.metadata())

        assertThrows(ServerConflictException::class.java) {
            second.upload(encoded("three", "Stale write"), staleRevision)
        }
        assertEquals("Second", ClipDatabaseFile.load(second.download().data, password).Entries.single().Text)
    }

    @Test
    fun providerConflictCopiesAreMergedBeforeUse() {
        val backend = FakeSharedFolderBackend(
            mutableMapOf(
                LocalHistoryStore.coreFileName to encoded("one", "Phone"),
                "clipman-history (conflicted copy).clipdb" to encoded("two", "Tablet")
            )
        )
        val client = SharedFolderStorageClient(backend, password)

        val merged = ClipDatabaseFile.load(client.download().data, password)

        assertEquals(setOf("Phone", "Tablet"), merged.Entries.map { it.Text }.toSet())
    }

    @Test
    fun providerCaseChangesDoNotHideCanonicalHistory() {
        val backend = FakeSharedFolderBackend(
            mutableMapOf("CLIPMAN-HISTORY.CLIPDB" to encoded("one", "Case changed"))
        )

        val downloaded = SharedFolderStorageClient(backend, password).download()

        assertEquals("Case changed", ClipDatabaseFile.load(downloaded.data, password).Entries.single().Text)
    }

    @Test
    fun firstWriteDetectsDatabaseCreatedByAnotherDevice() {
        val backend = FakeSharedFolderBackend()
        val client = SharedFolderStorageClient(backend, password)
        backend.files[LocalHistoryStore.coreFileName] = encoded("other", "Other device")

        assertThrows(ServerConflictException::class.java) {
            client.upload(encoded("local", "Local device"), "", createOnly = true)
        }
    }

    @Test
    fun conflictMatcherDoesNotTreatArbitraryFilesAsHistory() {
        assertTrue(
            SharedFolderStorageClient.isConflictSibling(
                "clipman-history (Pixel conflict).clipdb",
                LocalHistoryStore.coreFileName
            )
        )
        assertFalse(
            SharedFolderStorageClient.isConflictSibling(
                "clipman-history-backup.clipdb",
                LocalHistoryStore.coreFileName
            )
        )
        assertFalse(
            SharedFolderStorageClient.isConflictSibling(
                "family-notes.clipdb",
                LocalHistoryStore.coreFileName
            )
        )
    }

    @Test
    fun existingBackupFolderBecomesInitialSharedFolderOnlyWhenNeeded() {
        assertEquals(
            SharedFolderSelection("content://backup", "Cloud drive"),
            initialSharedFolderSelection("", "", "content://backup", "Cloud drive")
        )
        assertEquals(
            SharedFolderSelection("content://shared", "Shared clips"),
            initialSharedFolderSelection(
                "content://shared",
                "Shared clips",
                "content://backup",
                "Cloud drive"
            )
        )
    }

    private fun encoded(id: String, text: String): ByteArray = ClipDatabaseFile.save(
        ClipDatabase(Entries = listOf(ClipEntry(Id = id, Text = text))),
        password
    )

    private class FakeSharedFolderBackend(
        val files: MutableMap<String, ByteArray> = mutableMapOf()
    ) : SharedFolderDocumentBackend {
        override val identity = "fake://shared-folder"

        override fun list(): List<SharedFolderDocument> =
            files.keys.map { SharedFolderDocument(it, it) }

        override fun read(document: SharedFolderDocument): ByteArray =
            files.getValue(document.id).copyOf()

        override fun write(fileName: String, data: ByteArray) {
            files[fileName] = data.copyOf()
        }

        override fun delete(document: SharedFolderDocument) {
            files.remove(document.id)
        }
    }
}
