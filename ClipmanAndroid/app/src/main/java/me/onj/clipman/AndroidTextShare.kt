package me.onj.clipman

data class ExternalSharedTextImport(
    val id: Long,
    val text: String = "",
    val html: String = "",
    val errorMessage: String? = null
)

object AndroidTextSharePolicy {
    const val actionSend = "android.intent.action.SEND"

    fun rejectionMessage(action: String?, mimeType: String?, text: String): String? {
        if (action != actionSend) return "This share action is not supported by Clipman."
        if (mimeType.isNullOrBlank() || !mimeType.startsWith("text/", ignoreCase = true)) {
            return "Share text or a link to Clipman."
        }
        if (text.isBlank()) return "The shared item does not contain text or a link."
        return null
    }
}
