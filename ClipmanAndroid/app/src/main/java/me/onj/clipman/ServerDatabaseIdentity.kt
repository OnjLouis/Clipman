package me.onj.clipman

import java.util.Base64
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import java.security.MessageDigest

/**
 * The bucket identity derivations of sync-rules-spec.md section 2. Every id is
 * base64url without padding over HMAC-SHA256 keyed with SHA-256 of the trimmed
 * server token, and a blank token or password yields an empty id.
 */
object ServerDatabaseIdentity {
    private const val purpose = "Clipman.ServerDatabaseId.v1"
    private const val channelPurpose = "Clipman.ServerChannelId.v1"
    private const val syncRulesPurpose = "Clipman.ServerSyncRulesId.v1"

    fun fromTokenAndPassword(serverToken: String, historyPassword: String): String =
        derive(serverToken, historyPassword, "$purpose\n$historyPassword")

    /**
     * The bucket that holds one sync channel. The channel key is normalized
     * first, so an unroutable channel name addresses no bucket.
     */
    fun channelId(serverToken: String, historyPassword: String, channelKey: String): String {
        val key = SyncRuleEngine.channelKey(channelKey)
        if (key.isEmpty()) return ""
        return derive(serverToken, historyPassword, "$channelPurpose\n$historyPassword\n$key")
    }

    /** The bucket that holds the sync rules document. */
    fun syncRulesId(serverToken: String, historyPassword: String): String =
        derive(serverToken, historyPassword, "$syncRulesPurpose\n$historyPassword")

    private fun derive(serverToken: String, historyPassword: String, message: String): String {
        val token = serverToken.trim()
        if (token.isEmpty() || historyPassword.isEmpty()) return ""
        val key = MessageDigest.getInstance("SHA-256").digest(token.toByteArray(Charsets.UTF_8))
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        val digest = mac.doFinal(message.toByteArray(Charsets.UTF_8))
        return Base64.getUrlEncoder().withoutPadding().encodeToString(digest)
    }
}
