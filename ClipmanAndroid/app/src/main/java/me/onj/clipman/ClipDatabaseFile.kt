package me.onj.clipman

import kotlinx.serialization.json.Json
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.IOException
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.zip.GZIPInputStream
import java.util.zip.GZIPOutputStream
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec

object ClipDatabaseFile {
    internal const val maxDatabaseBlobBytes = 272 * 1024 * 1024
    internal const val maxDecompressedDatabaseBytes = 256 * 1024 * 1024
    private val compressedMagic = "CLIPDB1".toByteArray(Charsets.US_ASCII)
    private val encryptedMagic = "CLIPDB2".toByteArray(Charsets.US_ASCII)
    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
    }

    fun load(bytes: ByteArray, password: String): ClipDatabase {
        if (bytes.isEmpty()) return ClipDatabase()
        requireDatabaseBlobSize(bytes.size.toLong())
        val text = when {
            bytes.startsWith(encryptedMagic) -> readEncryptedText(bytes, password)
            bytes.startsWith(compressedMagic) -> readCompressedText(bytes.copyOfRange(compressedMagic.size, bytes.size))
            else -> readCompressedText(bytes)
        }
        return json.decodeFromString(ClipDatabase.serializer(), text)
    }

    fun isEncrypted(bytes: ByteArray): Boolean = bytes.startsWith(encryptedMagic)

    fun encryptedSalt(bytes: ByteArray): ByteArray? {
        val saltOffset = encryptedMagic.size + 1
        if (!bytes.startsWith(encryptedMagic) ||
            bytes.size < saltOffset + 16 ||
            bytes[encryptedMagic.size].toInt() != 1
        ) {
            return null
        }
        return bytes.copyOfRange(saltOffset, saltOffset + 16)
    }

    fun save(
        database: ClipDatabase,
        password: String,
        preferredSalt: ByteArray? = null
    ): ByteArray {
        val text = json.encodeToString(ClipDatabase.serializer(), database)
        val serialized = text.toByteArray(Charsets.UTF_8)
        requireSerializedJsonSize(serialized.size.toLong())
        val encoded = if (password.isNotEmpty()) {
            writeEncryptedText(serialized, password, preferredSalt)
        } else {
            compressedMagic + compress(serialized, maxDatabaseBlobBytes - compressedMagic.size)
        }
        requireDatabaseBlobSize(encoded.size.toLong())
        return encoded
    }

    private fun readCompressedText(bytes: ByteArray): String {
        try {
            val length = measureDecompressedSize(bytes)
            val decoded = ByteArray(length)
            GZIPInputStream(ByteArrayInputStream(bytes)).use { gzip ->
                var offset = 0
                while (offset < decoded.size) {
                    val count = gzip.read(decoded, offset, decoded.size - offset)
                    if (count < 0) throw IllegalArgumentException("The compressed Clipman database ended unexpectedly.")
                    offset += count
                }
                if (gzip.read() != -1) {
                    throw IllegalArgumentException("The Clipman database changed while it was being decompressed.")
                }
            }
            return decoded.toString(Charsets.UTF_8)
        } catch (error: DatabaseExpansionLimitException) {
            throw error
        } catch (error: IOException) {
            throw IllegalArgumentException("The Clipman database could not be decompressed.", error)
        }
    }

    private fun measureDecompressedSize(bytes: ByteArray): Int {
        val buffer = ByteArray(64 * 1024)
        var total = 0L
        GZIPInputStream(ByteArrayInputStream(bytes)).use { gzip ->
            while (true) {
                val count = gzip.read(buffer)
                if (count < 0) break
                total += count
                if (total > maxDecompressedDatabaseBytes) {
                    throw DatabaseExpansionLimitException(
                        "The Clipman database exceeds the 256 MiB decompressed size limit."
                    )
                }
            }
        }
        return total.toInt()
    }

    private fun readEncryptedText(bytes: ByteArray, password: String): String {
        if (password.isEmpty()) {
            throw DatabasePasswordRequiredException("This Clipman database is encrypted and needs its history password.")
        }
        if (bytes.size < encryptedMagic.size + 1 + 16 + 16 + 32) {
            throw IllegalArgumentException("The encrypted Clipman database is incomplete.")
        }

        var offset = encryptedMagic.size
        val version = bytes[offset++].toInt() and 0xff
        if (version != 1) {
            throw IllegalArgumentException("This encrypted Clipman database uses an unsupported format.")
        }

        val salt = bytes.copyOfRange(offset, offset + 16)
        offset += 16
        val iv = bytes.copyOfRange(offset, offset + 16)
        offset += 16
        val hmac = bytes.copyOfRange(bytes.size - 32, bytes.size)
        val cipherText = bytes.copyOfRange(offset, bytes.size - 32)
        val signed = bytes.copyOfRange(0, bytes.size - 32)
        val keys = deriveKeys(password, salt)
        val expected = hmacSha256(keys.macKey, signed)
        if (!MessageDigest.isEqual(expected, hmac)) {
            throw DatabasePasswordRequiredException("The Clipman database password is incorrect.")
        }

        val cipher = Cipher.getInstance("AES/CBC/PKCS5Padding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(keys.encryptionKey, "AES"), IvParameterSpec(iv))
        val compressed = cipher.doFinal(cipherText)
        return readCompressedText(compressed)
    }

    private fun writeEncryptedText(
        serialized: ByteArray,
        password: String,
        preferredSalt: ByteArray?
    ): ByteArray {
        val salt = preferredSalt?.takeIf { it.size == 16 }?.copyOf() ?: randomBytes(16)
        val iv = randomBytes(16)
        val keys = deriveKeys(password, salt)
        val maximumCompressedBytes = maxDatabaseBlobBytes -
            encryptedMagic.size - 1 - 16 - 16 - 32 - CipherBlockBytes
        val compressed = compress(serialized, maximumCompressedBytes)
        val cipher = Cipher.getInstance("AES/CBC/PKCS5Padding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(keys.encryptionKey, "AES"), IvParameterSpec(iv))
        val cipherText = cipher.doFinal(compressed)
        val signed = ByteArrayOutputStream().use { output ->
            output.write(encryptedMagic)
            output.write(byteArrayOf(1))
            output.write(salt)
            output.write(iv)
            output.write(cipherText)
            output.toByteArray()
        }
        val mac = hmacSha256(keys.macKey, signed)
        return ByteArrayOutputStream().use { output ->
            output.write(signed)
            output.write(mac)
            output.toByteArray()
        }
    }

    private fun compress(bytes: ByteArray, maximumBytes: Int): ByteArray =
        SizeLimitedByteArrayOutputStream(maximumBytes).use { output ->
            GZIPOutputStream(output).use { gzip ->
                gzip.write(bytes)
            }
            output.toByteArray()
        }

    internal fun requireDatabaseBlobSize(byteCount: Long) {
        if (byteCount > maxDatabaseBlobBytes) {
            throw DatabaseSizeLimitException("The Clipman database exceeds the 272 MiB container size limit.")
        }
    }

    internal fun requireSerializedJsonSize(byteCount: Long) {
        if (byteCount > maxDecompressedDatabaseBytes) {
            throw DatabaseExpansionLimitException(
                "The Clipman database exceeds the 256 MiB decompressed size limit."
            )
        }
    }

    internal fun readDatabaseBlob(
        input: InputStream,
        declaredLength: Long = -1L,
        maximumBytes: Int = maxDatabaseBlobBytes
    ): ByteArray {
        require(maximumBytes >= 0) { "The database read limit cannot be negative." }
        if (declaredLength > maximumBytes.toLong()) {
            throw DatabaseSizeLimitException("The Clipman database exceeds the 272 MiB container size limit.")
        }

        val initialCapacity = when {
            declaredLength in 0..maximumBytes.toLong() -> declaredLength.toInt()
            else -> minOf(maximumBytes, 64 * 1024)
        }
        val output = ByteArrayOutputStream(initialCapacity)
        val buffer = ByteArray(64 * 1024)
        var total = 0L
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            if (count == 0) continue
            total += count.toLong()
            if (total > maximumBytes.toLong()) {
                throw DatabaseSizeLimitException("The Clipman database exceeds the 272 MiB container size limit.")
            }
            output.write(buffer, 0, count)
        }
        return output.toByteArray()
    }

    private fun randomBytes(length: Int): ByteArray {
        val bytes = ByteArray(length)
        SecureRandom().nextBytes(bytes)
        return bytes
    }

    private fun deriveKeys(password: String, salt: ByteArray): KeyPair {
        val cacheId = derivedKeyCacheId(password, salt)
        synchronized(derivedKeyCache) {
            derivedKeyCache[cacheId]?.let { return it }
        }
        val spec = PBEKeySpec(password.toCharArray(), salt, 150_000, 512)
        val keyBytes = try {
            SecretKeyFactory.getInstance("PBKDF2WithHmacSHA1").generateSecret(spec).encoded
        } finally {
            spec.clearPassword()
        }
        val keys = KeyPair(
            encryptionKey = keyBytes.copyOfRange(0, 32),
            macKey = keyBytes.copyOfRange(32, 64)
        )
        synchronized(derivedKeyCache) {
            derivedKeyCache[cacheId] = keys
        }
        keyBytes.fill(0)
        return keys
    }

    private fun derivedKeyCacheId(password: String, salt: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256")
        digest.update(password.toByteArray(Charsets.UTF_8))
        digest.update(0)
        digest.update(salt)
        return digest.digest().joinToString("") { byte -> "%02x".format(byte) }
    }

    private fun hmacSha256(key: ByteArray, data: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(data)
    }

    private fun ByteArray.startsWith(prefix: ByteArray): Boolean {
        if (size < prefix.size) return false
        for (index in prefix.indices) {
            if (this[index] != prefix[index]) return false
        }
        return true
    }

    private data class KeyPair(val encryptionKey: ByteArray, val macKey: ByteArray)

    private val derivedKeyCache = object : LinkedHashMap<String, KeyPair>(8, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, KeyPair>?): Boolean =
            size > 8
    }

    private class SizeLimitedByteArrayOutputStream(private val maximumBytes: Int) : ByteArrayOutputStream() {
        override fun write(value: Int) {
            requireCapacity(1)
            super.write(value)
        }

        override fun write(bytes: ByteArray, offset: Int, length: Int) {
            requireCapacity(length)
            super.write(bytes, offset, length)
        }

        private fun requireCapacity(additionalBytes: Int) {
            if (count.toLong() + additionalBytes > maximumBytes) {
                throw DatabaseSizeLimitException("The Clipman database exceeds the 272 MiB container size limit.")
            }
        }
    }

    private const val CipherBlockBytes = 16
}

class DatabasePasswordRequiredException(message: String) : Exception(message)

class DatabaseExpansionLimitException(message: String) : IllegalArgumentException(message)

class DatabaseSizeLimitException(message: String) : IllegalArgumentException(message)
