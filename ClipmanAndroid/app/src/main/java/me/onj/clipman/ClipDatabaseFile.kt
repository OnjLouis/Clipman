package me.onj.clipman

import kotlinx.serialization.json.Json
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
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
    private val compressedMagic = "CLIPDB1".toByteArray(Charsets.US_ASCII)
    private val encryptedMagic = "CLIPDB2".toByteArray(Charsets.US_ASCII)
    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
    }

    fun load(bytes: ByteArray, password: String): ClipDatabase {
        if (bytes.isEmpty()) return ClipDatabase()
        val text = when {
            bytes.startsWith(encryptedMagic) -> readEncryptedText(bytes, password)
            bytes.startsWith(compressedMagic) -> readCompressedText(bytes.copyOfRange(compressedMagic.size, bytes.size))
            else -> readCompressedText(bytes)
        }
        return json.decodeFromString(ClipDatabase.serializer(), text)
    }

    fun save(database: ClipDatabase, password: String): ByteArray {
        val text = json.encodeToString(ClipDatabase.serializer(), database)
        return if (password.isNotEmpty()) {
            writeEncryptedText(text, password)
        } else {
            compressedMagic + compress(text.toByteArray(Charsets.UTF_8))
        }
    }

    private fun readCompressedText(bytes: ByteArray): String {
        GZIPInputStream(ByteArrayInputStream(bytes)).use { gzip ->
            return gzip.readBytes().toString(Charsets.UTF_8)
        }
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

    private fun writeEncryptedText(text: String, password: String): ByteArray {
        val salt = randomBytes(16)
        val iv = randomBytes(16)
        val keys = deriveKeys(password, salt)
        val compressed = compress(text.toByteArray(Charsets.UTF_8))
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

    private fun compress(bytes: ByteArray): ByteArray =
        ByteArrayOutputStream().use { output ->
            GZIPOutputStream(output).use { gzip ->
                gzip.write(bytes)
            }
            output.toByteArray()
        }

    private fun randomBytes(length: Int): ByteArray {
        val bytes = ByteArray(length)
        SecureRandom().nextBytes(bytes)
        return bytes
    }

    private fun deriveKeys(password: String, salt: ByteArray): KeyPair {
        val spec = PBEKeySpec(password.toCharArray(), salt, 150_000, 512)
        val keyBytes = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA1").generateSecret(spec).encoded
        return KeyPair(
            encryptionKey = keyBytes.copyOfRange(0, 32),
            macKey = keyBytes.copyOfRange(32, 64)
        )
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
}

class DatabasePasswordRequiredException(message: String) : Exception(message)
