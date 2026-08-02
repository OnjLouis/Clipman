package me.onj.clipman

import java.nio.charset.StandardCharsets
import java.util.Base64
import java.util.Locale

data class EmbeddedImageData(
    val filename: String,
    val altText: String,
    val mimeType: String,
    val bytes: ByteArray,
    val width: Int,
    val height: Int,
    val hasAlpha: Boolean
)

data class EncodedImageInfo(
    val mimeType: String,
    val width: Int,
    val height: Int,
    val hasAlpha: Boolean,
    val animated: Boolean
)

object EmbeddedImageRichText {
    const val maxStoredImageBytes = 512 * 1024
    const val maxHtmlBytes = 768 * 1024
    const val maxInputBytes = 16 * 1024 * 1024
    const val maxInputPixels = 16_000_000L
    const val maxInputDimension = 4096
    const val maxStoredDimension = 2048
    const val totalImageBudgetBytes = 8 * 1024 * 1024
    private const val maxFilenameCharacters = 120
    private const val maxAltCharacters = 200

    private val wrapperPattern = Regex(
        "^<img data-clipman-image=\"1\" data-clipman-filename=\"([^\"]*)\" alt=\"([^\"]*)\" src=\"data:(image/(?:jpeg|png));base64,([A-Za-z0-9+/]+={0,2})\">$"
    )

    fun wrap(filename: String, altText: String, mimeType: String, bytes: ByteArray): String {
        require(mimeType == "image/jpeg" || mimeType == "image/png") { "Only PNG and JPEG images are supported." }
        require(bytes.isNotEmpty() && bytes.size <= maxStoredImageBytes) { "The stored image exceeds Clipman's image limit." }
        val info = EncodedImageInspector.inspect(bytes) ?: error("The stored image is not a valid PNG or JPEG image.")
        require(info.mimeType == mimeType && !info.animated) { "The stored image format is not supported." }
        require(info.width <= maxStoredDimension && info.height <= maxStoredDimension) { "The stored image dimensions exceed Clipman's limit." }
        val cleanFilename = normalizeFilename(filename, mimeType)
        val expectedAlt = "Image: $cleanFilename"
        val cleanAlt = cleanAttributeText(altText, maxAltCharacters, expectedAlt)
        require(cleanAlt == expectedAlt) { "The embedded image accessibility label is not canonical." }
        val html = "<img data-clipman-image=\"1\" data-clipman-filename=\"${escape(cleanFilename)}\" alt=\"${escape(cleanAlt)}\" src=\"data:$mimeType;base64,${Base64.getEncoder().encodeToString(bytes)}\">"
        require(html.toByteArray(StandardCharsets.UTF_8).size <= maxHtmlBytes) { "The encoded image exceeds Clipman's rich-text limit." }
        return html
    }

    fun parse(payload: RichTextPayload?): EmbeddedImageData? {
        val html = payload?.HtmlFragment ?: return null
        if (html.toByteArray(StandardCharsets.UTF_8).size > maxHtmlBytes) return null
        val match = wrapperPattern.matchEntire(html) ?: return null
        val filename = unescape(match.groupValues[1]) ?: return null
        val alt = unescape(match.groupValues[2]) ?: return null
        val mime = match.groupValues[3].lowercase(Locale.ROOT)
        if (!isCanonicalFilename(filename, mime)) return null
        val bytes = runCatching { Base64.getDecoder().decode(match.groupValues[4]) }.getOrNull() ?: return null
        if (bytes.isEmpty() || bytes.size > maxStoredImageBytes) return null
        val info = EncodedImageInspector.inspect(bytes) ?: return null
        if (info.mimeType != mime || info.animated || info.width > maxStoredDimension || info.height > maxStoredDimension) return null
        val canonical = runCatching { wrap(filename, alt, mime, bytes) }.getOrNull() ?: return null
        if (canonical != html) return null
        return EmbeddedImageData(filename, alt, mime, bytes, info.width, info.height, info.hasAlpha)
    }

    fun totalStoredBytes(entries: Iterable<ClipEntry>): Long = entries.sumOf { entry ->
        parse(entry.RichText)?.bytes?.size?.toLong() ?: 0L
    }

    fun exceedsTotalBudget(entries: Iterable<ClipEntry>, fallbackText: String, imageBytes: Int): Boolean {
        val replacedBytes = entries.firstOrNull { it.Text == fallbackText }
            ?.let { parse(it.RichText)?.bytes?.size?.toLong() }
            ?: 0L
        return totalStoredBytes(entries) - replacedBytes + imageBytes > totalImageBudgetBytes
    }

    internal fun isWithinInputLimits(byteCount: Int, width: Int, height: Int): Boolean =
        byteCount in 1..maxInputBytes && width in 1..maxInputDimension && height in 1..maxInputDimension &&
            width.toLong() * height <= maxInputPixels

    fun fallbackText(filename: String, bytes: ByteArray): String {
        val clean = canonicalFilenameText(filename, "image")
        val digest = java.security.MessageDigest.getInstance("SHA-256").digest(bytes)
            .take(6)
            .joinToString("") { byte -> (byte.toInt() and 0xff).toString(16).padStart(2, '0') }
        return "Image: $clean ($digest)"
    }

    fun extensionFor(mimeType: String): String = if (mimeType == "image/png") "png" else "jpg"

    internal fun normalizeFilename(value: String, mimeType: String): String {
        val fallback = "Clipboard image.${extensionFor(mimeType)}"
        val sanitized = canonicalFilenameText(value, fallback)
        val matchingExtension = matchingExtension(sanitized, mimeType)
        val extension = matchingExtension ?: ".${extensionFor(mimeType)}"
        val stemWithPossibleImageExtension = if (matchingExtension != null) {
            sanitized.dropLast(matchingExtension.length)
        } else {
            sanitized.replace(Regex("(?i)\\.(?:jpe?g|png)$"), "")
        }
        val extensionLength = extension.codePointCount(0, extension.length)
        val stem = truncateCodePoints(stemWithPossibleImageExtension, maxFilenameCharacters - extensionLength)
            .trimEnd()
            .ifBlank { "Clipboard image" }
        val clean = "$stem$extension"
        require(isCanonicalFilename(clean, mimeType)) { "The embedded image filename must match its PNG or JPEG type." }
        return clean
    }

    private fun isCanonicalFilename(value: String, mimeType: String): Boolean {
        if (value.isBlank() || value.contains('/') || value.contains('\\') || value.contains(':')) return false
        if (value.codePointCount(0, value.length) > maxFilenameCharacters) return false
        if (containsForbiddenFilenameCodePoint(value)) return false
        if (canonicalFilenameText(value, "") != value) return false
        val extension = matchingExtension(value, mimeType) ?: return false
        return value.endsWith(extension)
    }

    private fun matchingExtension(value: String, mimeType: String): String? = when (mimeType) {
        "image/png" -> ".png".takeIf { value.endsWith(it, ignoreCase = true) }
        "image/jpeg" -> when {
            value.endsWith(".jpeg", ignoreCase = true) -> ".jpeg"
            value.endsWith(".jpg", ignoreCase = true) -> ".jpg"
            else -> null
        }
        else -> null
    }

    private fun truncateCodePoints(value: String, maximum: Int): String {
        if (value.codePointCount(0, value.length) <= maximum) return value
        return value.substring(0, value.offsetByCodePoints(0, maximum))
    }

    private fun containsForbiddenFilenameCodePoint(value: String): Boolean {
        var offset = 0
        while (offset < value.length) {
            val codePoint = value.codePointAt(offset)
            val type = Character.getType(codePoint)
            if (type == Character.CONTROL.toInt() ||
                type == Character.FORMAT.toInt() ||
                type == Character.LINE_SEPARATOR.toInt() ||
                type == Character.PARAGRAPH_SEPARATOR.toInt() ||
                type == Character.SURROGATE.toInt() ||
                codePoint == 0xfffd ||
                isBidiControl(codePoint)) {
                return true
            }
            offset += Character.charCount(codePoint)
        }
        return false
    }

    private fun isBidiControl(codePoint: Int): Boolean =
        codePoint == 0x061c || codePoint == 0x200e || codePoint == 0x200f ||
            codePoint in 0x202a..0x202e || codePoint in 0x2066..0x2069

    private fun cleanAttributeText(value: String, maxCharacters: Int, fallback: String): String {
        val clean = buildString {
            var offset = 0
            var pendingSpace = false
            while (offset < value.length) {
                val codePoint = value.codePointAt(offset)
                val type = Character.getType(codePoint)
                val isCollapsibleSpace = isUnicodeWhitespace(codePoint)
                if (isCollapsibleSpace) {
                    pendingSpace = isNotEmpty()
                } else if (type != Character.CONTROL.toInt() &&
                    type != Character.FORMAT.toInt() &&
                    type != Character.SURROGATE.toInt() &&
                    codePoint != 0xfffd &&
                    !isBidiControl(codePoint)) {
                    if (pendingSpace) append(' ')
                    appendCodePoint(codePoint)
                    pendingSpace = false
                }
                offset += Character.charCount(codePoint)
            }
        }.trim().ifBlank { fallback }
        if (clean.codePointCount(0, clean.length) <= maxCharacters) return clean
        return clean.substring(0, clean.offsetByCodePoints(0, maxCharacters)).trimEnd()
    }

    private fun canonicalFilenameText(value: String, fallback: String): String {
        val basename = value.replace('\\', '/').substringAfterLast('/')
        val clean = buildString {
            var offset = 0
            var pendingSpace = false
            while (offset < basename.length) {
                val codePoint = basename.codePointAt(offset)
                val type = Character.getType(codePoint)
                val isCollapsibleSpace = isUnicodeWhitespace(codePoint)
                if (isCollapsibleSpace) {
                    pendingSpace = isNotEmpty()
                } else if (type != Character.CONTROL.toInt() &&
                    type != Character.FORMAT.toInt() &&
                    type != Character.SURROGATE.toInt() &&
                    codePoint != 0xfffd &&
                    !isBidiControl(codePoint) &&
                    codePoint != '/'.code && codePoint != '\\'.code && codePoint != ':'.code) {
                    if (pendingSpace) append(' ')
                    appendCodePoint(codePoint)
                    pendingSpace = false
                }
                offset += Character.charCount(codePoint)
            }
        }.trim()
        return clean.ifBlank { fallback }
    }

    private fun isUnicodeWhitespace(codePoint: Int): Boolean =
        codePoint in 0x0009..0x000d || codePoint == 0x0020 || codePoint == 0x0085 ||
            codePoint == 0x00a0 || codePoint == 0x1680 || codePoint in 0x2000..0x200a ||
            codePoint == 0x2028 || codePoint == 0x2029 || codePoint == 0x202f ||
            codePoint == 0x205f || codePoint == 0x3000

    private fun escape(value: String): String = buildString(value.length) {
        value.forEach { character ->
            append(
                when (character) {
                    '&' -> "&amp;"
                    '"' -> "&quot;"
                    '<' -> "&lt;"
                    '>' -> "&gt;"
                    else -> character
                }
            )
        }
    }

    private fun unescape(value: String): String? {
        if (Regex("&(?!amp;|quot;|lt;|gt;)").containsMatchIn(value)) return null
        return value.replace("&quot;", "\"")
            .replace("&lt;", "<")
            .replace("&gt;", ">")
            .replace("&amp;", "&")
    }
}

object EncodedImageInspector {
    private val pngSignature = byteArrayOf(0x89.toByte(), 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a)

    fun inspect(bytes: ByteArray): EncodedImageInfo? = when {
        bytes.size >= pngSignature.size && bytes.copyOfRange(0, pngSignature.size).contentEquals(pngSignature) -> inspectPng(bytes)
        bytes.size >= 4 && bytes[0] == 0xff.toByte() && bytes[1] == 0xd8.toByte() -> inspectJpeg(bytes)
        else -> null
    }

    private fun inspectPng(bytes: ByteArray): EncodedImageInfo? {
        if (bytes.size < 33 || ascii(bytes, 12, 4) != "IHDR") return null
        val width = int32(bytes, 16)
        val height = int32(bytes, 20)
        if (width <= 0 || height <= 0) return null
        val colorType = bytes[25].toInt() and 0xff
        var animated = false
        var offset = 8
        while (offset + 12 <= bytes.size) {
            val length = int32(bytes, offset)
            if (length < 0 || offset + 12L + length > bytes.size) return null
            val type = ascii(bytes, offset + 4, 4)
            if (type == "acTL") animated = true
            offset += 12 + length
            if (type == "IEND") break
        }
        return EncodedImageInfo("image/png", width, height, colorType == 4 || colorType == 6, animated)
    }

    private fun inspectJpeg(bytes: ByteArray): EncodedImageInfo? {
        var offset = 2
        while (offset + 3 < bytes.size) {
            while (offset < bytes.size && bytes[offset] != 0xff.toByte()) offset++
            while (offset < bytes.size && bytes[offset] == 0xff.toByte()) offset++
            if (offset >= bytes.size) break
            val marker = bytes[offset].toInt() and 0xff
            offset++
            if (marker == 0xd9 || marker == 0xda) break
            if (marker in 0xd0..0xd7 || marker == 0x01) continue
            if (offset + 2 > bytes.size) return null
            val length = uint16(bytes, offset)
            if (length < 2 || offset + length > bytes.size) return null
            if (marker in setOf(0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf)) {
                if (length < 7) return null
                val height = uint16(bytes, offset + 3)
                val width = uint16(bytes, offset + 5)
                if (width <= 0 || height <= 0) return null
                return EncodedImageInfo("image/jpeg", width, height, false, false)
            }
            offset += length
        }
        return null
    }

    private fun int32(bytes: ByteArray, offset: Int): Int {
        if (offset + 4 > bytes.size) return -1
        return ((bytes[offset].toInt() and 0xff) shl 24) or
            ((bytes[offset + 1].toInt() and 0xff) shl 16) or
            ((bytes[offset + 2].toInt() and 0xff) shl 8) or
            (bytes[offset + 3].toInt() and 0xff)
    }

    private fun uint16(bytes: ByteArray, offset: Int): Int {
        if (offset + 2 > bytes.size) return -1
        return ((bytes[offset].toInt() and 0xff) shl 8) or (bytes[offset + 1].toInt() and 0xff)
    }

    private fun ascii(bytes: ByteArray, offset: Int, length: Int): String =
        if (offset + length <= bytes.size) String(bytes, offset, length, StandardCharsets.US_ASCII) else ""
}
