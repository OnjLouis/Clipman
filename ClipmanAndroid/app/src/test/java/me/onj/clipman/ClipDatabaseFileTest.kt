package me.onj.clipman

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.util.zip.GZIPOutputStream
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class ClipDatabaseFileTest {
    @Test
    fun normalDatabaseStillRoundTrips() {
        val database = ClipDatabase(Entries = listOf(ClipEntry(Text = "Bounded database test")))

        assertEquals(database, ClipDatabaseFile.load(ClipDatabaseFile.save(database, ""), ""))
    }

    @Test
    fun encryptedRewriteCanPreserveSaltWithoutReusingCiphertext() {
        val password = "test-history-password"
        val first = ClipDatabaseFile.save(
            ClipDatabase(Entries = listOf(ClipEntry(Text = "Original"))),
            password
        )
        val salt = requireNotNull(ClipDatabaseFile.encryptedSalt(first))
        val updated = ClipDatabase(Entries = listOf(ClipEntry(Text = "Updated")))
        val second = ClipDatabaseFile.save(updated, password, preferredSalt = salt)

        assertArrayEquals(salt, ClipDatabaseFile.encryptedSalt(second))
        assertTrue(!first.contentEquals(second))
        assertEquals(updated, ClipDatabaseFile.load(second, password))
    }

    @Test
    fun invalidPreferredSaltIsReplacedWithAValidSalt() {
        val encoded = ClipDatabaseFile.save(
            ClipDatabase(Entries = listOf(ClipEntry(Text = "Entry"))),
            "test-history-password",
            preferredSalt = byteArrayOf(1, 2, 3)
        )

        assertEquals(16, ClipDatabaseFile.encryptedSalt(encoded)?.size)
    }

    @Test
    fun databaseContainerLimitIs272MiBAndAcceptsExactThenRejectsOneByteOver() {
        assertEquals(272 * 1024 * 1024, ClipDatabaseFile.maxDatabaseBlobBytes)
        ClipDatabaseFile.requireDatabaseBlobSize(ClipDatabaseFile.maxDatabaseBlobBytes.toLong())

        val error = assertThrows(DatabaseSizeLimitException::class.java) {
            ClipDatabaseFile.requireDatabaseBlobSize(ClipDatabaseFile.maxDatabaseBlobBytes.toLong() + 1L)
        }
        assertTrue(error.message.orEmpty().contains("272 MiB"))
    }

    @Test
    fun serializedJsonLimitAcceptsExactAndRejectsOneByteOver() {
        ClipDatabaseFile.requireSerializedJsonSize(ClipDatabaseFile.maxDecompressedDatabaseBytes.toLong())

        val error = assertThrows(DatabaseExpansionLimitException::class.java) {
            ClipDatabaseFile.requireSerializedJsonSize(ClipDatabaseFile.maxDecompressedDatabaseBytes.toLong() + 1L)
        }
        assertTrue(error.message.orEmpty().contains("256 MiB"))
    }

    @Test
    fun boundedDatabaseReaderAcceptsExactLimitAndRejectsStreamedByteOver() {
        val exact = ByteArray(64) { it.toByte() }
        assertArrayEquals(
            exact,
            ClipDatabaseFile.readDatabaseBlob(ByteArrayInputStream(exact), exact.size.toLong(), exact.size)
        )

        val error = assertThrows(DatabaseSizeLimitException::class.java) {
            ClipDatabaseFile.readDatabaseBlob(ByteArrayInputStream(exact + 64), -1L, exact.size)
        }
        assertTrue(error.message.orEmpty().contains("272 MiB"))
    }

    @Test
    fun boundedDatabaseReaderRejectsOversizedDeclaredLengthBeforeReading() {
        val unreadable = object : InputStream() {
            override fun read(): Int = error("The stream must not be read.")
        }

        assertThrows(DatabaseSizeLimitException::class.java) {
            ClipDatabaseFile.readDatabaseBlob(unreadable, 65L, 64)
        }
    }

    @Test(timeout = 120_000)
    fun gzipExpansionBeyondProductionLimitFailsWithoutAllocatingTheExpansion() {
        val compressed = gzipZeroes(ClipDatabaseFile.maxDecompressedDatabaseBytes.toLong() + 1L)
        assertTrue("The practical expansion fixture should remain compact.", compressed.size < 512 * 1024)

        val error = assertThrows(DatabaseExpansionLimitException::class.java) {
            ClipDatabaseFile.load(compressed, "")
        }
        assertTrue(error.message.orEmpty().contains("256 MiB"))
    }

    private fun gzipZeroes(expandedBytes: Long): ByteArray {
        val block = ByteArray(1024 * 1024)
        return ByteArrayOutputStream().use { output ->
            GZIPOutputStream(output).use { gzip ->
                var remaining = expandedBytes
                while (remaining > 0) {
                    val count = minOf(block.size.toLong(), remaining).toInt()
                    gzip.write(block, 0, count)
                    remaining -= count
                }
            }
            output.toByteArray()
        }
    }
}
