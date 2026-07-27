package me.onj.clipman

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import java.util.Base64

data class AndroidClipboardContent(
    val text: String,
    val richText: RichTextPayload?
)

object RichTextClipboard {
    private const val maxHtmlBytes = 768 * 1024
    private const val maxRtfBytes = 1024 * 1024
    private const val maxCombinedBytes = 1792 * 1024

    fun read(context: Context, includeRichText: Boolean): AndroidClipboardContent {
        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val clip = clipboard.primaryClip ?: return AndroidClipboardContent("", null)
        if (clip.itemCount <= 0) return AndroidClipboardContent("", null)
        val item = clip.getItemAt(0)
        val text = item.coerceToText(context)?.toString().orEmpty()
        val html = if (includeRichText) item.htmlText.orEmpty() else ""
        return AndroidClipboardContent(
            text = text,
            richText = normalize(RichTextPayload(
                HtmlFragment = html,
                PreferredFormat = if (html.isNotEmpty()) "Html" else ""
            ))
        )
    }

    fun write(context: Context, entry: ClipEntry, includeRichText: Boolean) {
        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val richText = if (includeRichText) normalize(entry.RichText) else null
        val clip = if (!richText?.HtmlFragment.isNullOrEmpty()) {
            ClipData.newHtmlText("Clipman entry", entry.Text, richText!!.HtmlFragment)
        } else {
            ClipData.newPlainText("Clipman entry", entry.Text)
        }
        clipboard.setPrimaryClip(clip)
    }

    fun normalize(payload: RichTextPayload?): RichTextPayload? {
        payload ?: return null
        var html = payload.HtmlFragment
        if (html.toByteArray(Charsets.UTF_8).size > maxHtmlBytes) html = ""
        var rtf = decodeBase64(payload.RtfBase64)
        if (rtf != null && rtf.size > maxRtfBytes) rtf = null
        if (html.toByteArray(Charsets.UTF_8).size + (rtf?.size ?: 0) > maxCombinedBytes) {
            if (html.isNotEmpty()) rtf = null else return null
        }
        if (html.isEmpty() && (rtf == null || rtf.isEmpty())) return null
        val preferRtf = payload.PreferredFormat.equals("Rtf", ignoreCase = true) && rtf != null && rtf.isNotEmpty()
        return RichTextPayload(
            Version = 1,
            HtmlFragment = html,
            RtfBase64 = rtf?.let { Base64.getEncoder().encodeToString(it) }.orEmpty(),
            PreferredFormat = if (preferRtf) "Rtf" else if (html.isNotEmpty()) "Html" else "Rtf"
        )
    }

    private fun decodeBase64(value: String): ByteArray? {
        if (value.isBlank()) return null
        return runCatching { Base64.getDecoder().decode(value) }.getOrNull()
    }
}
