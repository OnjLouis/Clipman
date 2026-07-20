package me.onj.clipman

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.security.KeyStore
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class AndroidSettings(context: Context) {
    private val preferences = context.getSharedPreferences("clipman-android-settings", Context.MODE_PRIVATE)
    private val crypto = SettingsCrypto()

    var serverUrl: String
        get() = getString("serverUrl")
        set(value) = putString("serverUrl", value)

    var serverToken: String
        get() = getString("serverToken")
        set(value) = putString("serverToken", value)

    var historyPassword: String
        get() = getString("historyPassword")
        set(value) = putString("historyPassword", value)

    var deviceName: String
        get() = preferences.getString("deviceName", "")?.takeIf { it.isNotBlank() } ?: defaultDeviceName()
        set(value) {
            val clean = value.trim()
            val editor = preferences.edit()
            if (clean.isBlank()) {
                editor.remove("deviceName")
            } else {
                editor.putString("deviceName", clean)
            }
            editor.apply()
        }

    var copyRemoteToClipboard: Boolean
        get() = preferences.getBoolean("copyRemoteToClipboard", false)
        set(value) = preferences.edit().putBoolean("copyRemoteToClipboard", value).apply()

    var playSounds: Boolean
        get() = preferences.getBoolean("playSounds", true)
        set(value) = preferences.edit().putBoolean("playSounds", value).apply()

    var useHaptics: Boolean
        get() = preferences.getBoolean("useHaptics", false)
        set(value) = preferences.edit().putBoolean("useHaptics", value).apply()

    private fun getString(key: String): String {
        val value = preferences.getString(key, "") ?: ""
        if (value.isBlank()) return ""
        return crypto.decrypt(value).getOrElse { "" }
    }

    private fun putString(key: String, value: String) {
        val editor = preferences.edit()
        if (value.isBlank()) {
            editor.remove(key)
        } else {
            editor.putString(key, crypto.encrypt(value))
        }
        editor.apply()
    }

    companion object {
        fun defaultDeviceName(): String {
            val model = android.os.Build.MODEL?.trim().orEmpty()
            return if (model.isBlank()) "Android" else "Android $model"
        }
    }
}

private class SettingsCrypto {
    private val keyAlias = "ClipmanAndroid.Settings.v1"
    private val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    fun encrypt(value: String): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, getOrCreateKey())
        val iv = cipher.iv
        val encrypted = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        return "v1:${base64(iv)}:${base64(encrypted)}"
    }

    fun decrypt(value: String): Result<String> = runCatching {
        val parts = value.split(":")
        if (parts.size != 3 || parts[0] != "v1") return@runCatching ""
        val iv = fromBase64(parts[1])
        val encrypted = fromBase64(parts[2])
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, getOrCreateKey(), GCMParameterSpec(128, iv))
        cipher.doFinal(encrypted).toString(Charsets.UTF_8)
    }

    private fun getOrCreateKey(): SecretKey {
        val existing = keyStore.getEntry(keyAlias, null) as? KeyStore.SecretKeyEntry
        if (existing != null) return existing.secretKey

        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        val spec = KeyGenParameterSpec.Builder(
            keyAlias,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setRandomizedEncryptionRequired(true)
            .build()
        generator.init(spec)
        return generator.generateKey()
    }

    private fun base64(bytes: ByteArray): String =
        Base64.getEncoder().withoutPadding().encodeToString(bytes)

    private fun fromBase64(value: String): ByteArray =
        Base64.getDecoder().decode(value)
}
