package me.onj.clipman

import java.util.Base64
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import java.security.MessageDigest

object ServerDatabaseIdentity {
    private const val purpose = "Clipman.ServerDatabaseId.v1"
    private const val noPasswordMarker = "<clipman-no-history-password>"

    fun fromTokenAndPassword(serverToken: String, historyPassword: String): String {
        val token = serverToken.trim()
        if (token.isEmpty()) return ""
        val password = historyPassword.ifEmpty { noPasswordMarker }
        val key = MessageDigest.getInstance("SHA-256").digest(token.toByteArray(Charsets.UTF_8))
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        val digest = mac.doFinal("$purpose\n$password".toByteArray(Charsets.UTF_8))
        return Base64.getUrlEncoder().withoutPadding().encodeToString(digest)
    }
}
