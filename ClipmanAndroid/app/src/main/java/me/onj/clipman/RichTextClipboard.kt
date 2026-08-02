package me.onj.clipman

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import java.util.Base64

data class AndroidClipboardContent(
    val text: String,
    val richText: RichTextPayload?
)

internal data class ClipboardWritePlan(
    val plainText: String,
    val html: String?,
    val embeddedImage: EmbeddedImageData?
)

object RichTextClipboard {
    private const val maxHtmlBytes = 768 * 1024
    private const val maxRtfBytes = 1024 * 1024
    private const val maxCombinedBytes = 1792 * 1024

    fun read(
        context: Context,
        includeRichText: Boolean,
        includeImages: Boolean = false,
        existingEntries: List<ClipEntry> = emptyList(),
        forHistoryCapture: Boolean = false
    ): AndroidClipboardContent {
        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val clip = clipboard.primaryClip ?: return AndroidClipboardContent("", null)
        if (clip.itemCount <= 0) return AndroidClipboardContent("", null)
        if (AndroidImageClipboard.hasImage(clip)) {
            if (!includeRichText) {
                if (forHistoryCapture) throw ImageClipboardException("Enable Rich Text history before adding clipboard images.")
                return AndroidClipboardContent("", null)
            }
            if (!includeImages) {
                throw ImageClipboardException("Enable Include images in Rich Text history before adding clipboard images.")
            }
            return AndroidImageClipboard.read(context, clip, existingEntries)
        }
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
        val plan = planWrite(entry, includeRichText)
        val clip = if (plan.embeddedImage != null) {
            AndroidImageClipboard.createNativeClip(
                context,
                plan.plainText,
                requireNotNull(plan.html),
                plan.embeddedImage
            )
        } else if (!plan.html.isNullOrEmpty()) {
            ClipData.newHtmlText("Clipman entry", plan.plainText, plan.html)
        } else {
            ClipData.newPlainText("Clipman entry", plan.plainText)
        }
        clipboard.setPrimaryClip(clip)
    }

    internal fun planWrite(entry: ClipEntry, includeRichText: Boolean): ClipboardWritePlan {
        val storedRichText = normalize(entry.RichText)
        val embeddedImage = EmbeddedImageRichText.parse(storedRichText)
        if (embeddedImage != null) {
            return ClipboardWritePlan(entry.Text, storedRichText!!.HtmlFragment, embeddedImage)
        }
        val html = if (includeRichText) storedRichText?.HtmlFragment?.takeIf { it.isNotEmpty() } else null
        return ClipboardWritePlan(entry.Text, html, null)
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
