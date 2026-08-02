package me.onj.clipman

import android.content.ClipData
import android.content.ClipDescription
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.provider.OpenableColumns
import androidx.core.content.FileProvider
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import kotlin.math.roundToInt

class ImageClipboardException(message: String) : Exception(message)

data class ExternalSharedImageImport(
    val id: Long,
    val image: EmbeddedImageData? = null,
    val errorMessage: String? = null,
    val isReading: Boolean = false
)

object AndroidImageSharePolicy {
    const val actionSend = "android.intent.action.SEND"
    const val actionSendMultiple = "android.intent.action.SEND_MULTIPLE"

    fun rejectionMessage(action: String?, mimeType: String?, distinctStreamCount: Int): String? {
        if (action == actionSendMultiple || distinctStreamCount > 1) {
            return "Clipman can add one shared photo at a time."
        }
        if (action != actionSend) return "This share action is not supported by Clipman."
        if (mimeType.isNullOrBlank() || !mimeType.startsWith("image/", ignoreCase = true)) {
            return "Share a photo in PNG or JPEG format to Clipman."
        }
        if (distinctStreamCount == 0) return "The shared photo does not contain readable image data."
        return null
    }
}

object AndroidImageClipboard {
    fun hasImage(clip: ClipData): Boolean {
        if (clip.itemCount <= 0) return false
        val description = clip.description
        if ((0 until description.mimeTypeCount).any { description.getMimeType(it).startsWith("image/") }) return true
        val html = clip.getItemAt(0).htmlText
        return EmbeddedImageRichText.parse(html?.let { RichTextPayload(HtmlFragment = it, PreferredFormat = "Html") }) != null
    }

    fun read(context: Context, clip: ClipData, existingEntries: List<ClipEntry>): AndroidClipboardContent {
        if (clip.itemCount != 1) {
            throw ImageClipboardException("Clipman can add one standalone clipboard image at a time.")
        }
        val item = clip.getItemAt(0)
        val existingWrapper = item.htmlText?.let {
            EmbeddedImageRichText.parse(RichTextPayload(HtmlFragment = it, PreferredFormat = "Html"))
        }
        val image = if (existingWrapper != null) {
            existingWrapper
        } else {
            val uri = item.uri ?: throw ImageClipboardException("The Android clipboard does not expose readable PNG or JPEG image data.")
            val bytes = context.contentResolver.openInputStream(uri)?.use { it.readBounded(EmbeddedImageRichText.maxInputBytes) }
                ?: throw ImageClipboardException("The Android clipboard image could not be read.")
            prepareImage(bytes, displayName(context, uri))
        }

        return contentForPreparedImage(image, existingEntries)
    }

    fun readSharedImage(context: Context, uri: Uri): EmbeddedImageData {
        val bytes = context.contentResolver.openInputStream(uri)?.use {
            it.readBounded(EmbeddedImageRichText.maxInputBytes)
        } ?: throw ImageClipboardException("The shared photo could not be read.")
        return prepareImage(bytes, displayName(context, uri))
    }

    fun contentForPreparedImage(
        image: EmbeddedImageData,
        existingEntries: List<ClipEntry>
    ): AndroidClipboardContent {
        val fallback = EmbeddedImageRichText.fallbackText(image.filename, image.bytes)
        if (EmbeddedImageRichText.exceedsTotalBudget(existingEntries, fallback, image.bytes.size)) {
            throw ImageClipboardException("Clipman's 8 MiB embedded-image history limit has been reached. Delete an image entry before adding another.")
        }
        val html = EmbeddedImageRichText.wrap(image.filename, image.altText, image.mimeType, image.bytes)
        return AndroidClipboardContent(
            text = fallback,
            richText = RichTextPayload(HtmlFragment = html, PreferredFormat = "Html")
        )
    }

    fun createNativeClip(
        context: Context,
        plainText: String,
        html: String,
        image: EmbeddedImageData
    ): ClipData {
        val directory = File(context.cacheDir, "clipboard-images")
        check(directory.exists() || directory.mkdirs()) { "Could not prepare the image clipboard." }
        directory.listFiles()?.forEach { it.delete() }
        val safeName = image.filename
            .replace(Regex("[^A-Za-z0-9._ -]"), "_")
            .trim()
            .take(100)
            .ifBlank { "Clipman image.${EmbeddedImageRichText.extensionFor(image.mimeType)}" }
        val filename = ensureExtension(safeName, image.mimeType)
        val file = File(directory, filename)
        file.writeBytes(image.bytes)
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
        val description = ClipDescription(
            "Clipman image",
            arrayOf(image.mimeType, ClipDescription.MIMETYPE_TEXT_HTML, ClipDescription.MIMETYPE_TEXT_PLAIN)
        )
        return ClipData(description, ClipData.Item(plainText, html, null, uri))
    }

    fun decodePreview(image: EmbeddedImageData): Bitmap? =
        BitmapFactory.decodeByteArray(image.bytes, 0, image.bytes.size)

    internal fun prepareImage(input: ByteArray, filenameHint: String): EmbeddedImageData {
        if (input.isEmpty()) throw ImageClipboardException("The Android clipboard image is empty.")
        if (input.size > EmbeddedImageRichText.maxInputBytes) {
            throw ImageClipboardException("The Android clipboard image exceeds Clipman's 16 MiB input limit.")
        }
        val info = EncodedImageInspector.inspect(input)
            ?: throw ImageClipboardException("Only standalone PNG and JPEG clipboard images are supported.")
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(input, 0, input.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0 || bounds.outWidth != info.width || bounds.outHeight != info.height) {
            throw ImageClipboardException("The Android clipboard image has invalid or inconsistent dimensions.")
        }
        val boundsMime = bounds.outMimeType?.lowercase().orEmpty()
        if (boundsMime != info.mimeType) {
            throw ImageClipboardException("The Android clipboard image type could not be validated.")
        }
        if (info.animated) throw ImageClipboardException("Animated images are not supported in Rich Text history.")
        if (!EmbeddedImageRichText.isWithinInputLimits(input.size, info.width, info.height)) {
            throw ImageClipboardException("The Android clipboard image exceeds Clipman's 4096-pixel or 16-megapixel input limit.")
        }
        val filename = normalizedFilename(filenameHint, info.mimeType)
        if (input.size <= EmbeddedImageRichText.maxStoredImageBytes &&
            info.width <= EmbeddedImageRichText.maxStoredDimension && info.height <= EmbeddedImageRichText.maxStoredDimension) {
            return EmbeddedImageData(filename, "Image: $filename", info.mimeType, input, info.width, info.height, info.hasAlpha)
        }

        val metadata = BoundedImageMetadata.extract(input, info.mimeType)
        val sampleSize = calculateSampleSize(info.width, info.height)
        val options = BitmapFactory.Options().apply {
            inSampleSize = sampleSize
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        val decoded = BitmapFactory.decodeByteArray(input, 0, input.size, options)
            ?: throw ImageClipboardException("The Android clipboard image could not be decoded safely.")
        try {
            var targetWidth = decoded.width
            var targetHeight = decoded.height
            val initialScale = minOf(
                1.0,
                EmbeddedImageRichText.maxStoredDimension.toDouble() / maxOf(targetWidth, targetHeight)
            )
            targetWidth = maxOf(1, (targetWidth * initialScale).roundToInt())
            targetHeight = maxOf(1, (targetHeight * initialScale).roundToInt())
            var scaled = if (targetWidth == decoded.width && targetHeight == decoded.height) decoded else
                Bitmap.createScaledBitmap(decoded, targetWidth, targetHeight, true)
            try {
                repeat(8) {
                    val encoded = encodeBitmap(scaled, info.mimeType, metadata)
                    if (encoded != null) {
                        val encodedInfo = EncodedImageInspector.inspect(encoded)
                            ?: throw ImageClipboardException("Clipman could not validate the optimized image.")
                        val outputName = normalizedFilename(filename, encodedInfo.mimeType)
                        return EmbeddedImageData(
                            outputName,
                            "Image: $outputName",
                            encodedInfo.mimeType,
                            encoded,
                            encodedInfo.width,
                            encodedInfo.height,
                            encodedInfo.hasAlpha
                        )
                    }
                    val nextWidth = maxOf(1, (scaled.width * 0.82).roundToInt())
                    val nextHeight = maxOf(1, (scaled.height * 0.82).roundToInt())
                    if (nextWidth == scaled.width && nextHeight == scaled.height) return@repeat
                    val smaller = Bitmap.createScaledBitmap(scaled, nextWidth, nextHeight, true)
                    if (scaled !== decoded) scaled.recycle()
                    scaled = smaller
                }
            } finally {
                if (scaled !== decoded) scaled.recycle()
            }
        } finally {
            decoded.recycle()
        }
        throw ImageClipboardException("The image could not be optimized below Clipman's 512 KiB storage limit.")
    }

    private fun encodeBitmap(bitmap: Bitmap, mimeType: String, metadata: List<ByteArray>): ByteArray? {
        if (mimeType == "image/png") {
            val output = ByteArrayOutputStream()
            if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)) return null
            return BoundedImageMetadata.inject(output.toByteArray(), mimeType, metadata)
                .takeIf { it.size <= EmbeddedImageRichText.maxStoredImageBytes }
        }
        for (quality in listOf(92, 86, 80, 72, 64, 56, 48)) {
            val output = ByteArrayOutputStream()
            if (!bitmap.compress(Bitmap.CompressFormat.JPEG, quality, output)) continue
            val encoded = BoundedImageMetadata.inject(output.toByteArray(), mimeType, metadata)
            if (encoded.size <= EmbeddedImageRichText.maxStoredImageBytes) return encoded
        }
        return null
    }

    private fun calculateSampleSize(width: Int, height: Int): Int {
        var sample = 1
        while (maxOf(width / sample, height / sample) > EmbeddedImageRichText.maxStoredDimension * 2) sample *= 2
        return sample
    }

    private fun displayName(context: Context, uri: Uri): String {
        val fromProvider = runCatching {
            context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getString(0) else null
            }
        }.getOrNull()
        return fromProvider
            ?.replace('\\', '/')
            ?.substringAfterLast('/')
            ?.takeIf(::isMeaningfulFilename)
            ?: "Clipboard image"
    }

    private fun isMeaningfulFilename(value: String): Boolean {
        val stem = value.replace(Regex("(?i)\\.(?:jpe?g|png)$"), "").trim()
        if (stem.isBlank() || stem.all(Char::isDigit)) return false
        if (Regex("(?i)^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$").matches(stem)) {
            return false
        }
        return !LinkPresentation.looksHighEntropy(stem)
    }

    private fun normalizedFilename(value: String, mimeType: String): String {
        return EmbeddedImageRichText.normalizeFilename(value, mimeType)
    }

    private fun ensureExtension(value: String, mimeType: String): String {
        val extension = EmbeddedImageRichText.extensionFor(mimeType)
        val withoutKnown = value.replace(Regex("(?i)\\.(?:jpe?g|png)$"), "")
        return "$withoutKnown.$extension"
    }

    private fun InputStream.readBounded(maxBytes: Int): ByteArray {
        val output = ByteArrayOutputStream(minOf(maxBytes, 64 * 1024))
        val buffer = ByteArray(16 * 1024)
        var total = 0
        while (true) {
            val count = read(buffer)
            if (count < 0) break
            total += count
            if (total > maxBytes) throw ImageClipboardException("The Android clipboard image exceeds Clipman's 16 MiB input limit.")
            output.write(buffer, 0, count)
        }
        return output.toByteArray()
    }
}

object BoundedImageMetadata {
    private const val maxMetadataBytes = 64 * 1024
    private val pngMetadataTypes = setOf("eXIf", "iCCP", "iTXt", "pHYs", "tEXt", "tIME", "zTXt")

    fun extract(bytes: ByteArray, mimeType: String): List<ByteArray> = when (mimeType) {
        "image/jpeg" -> extractJpeg(bytes)
        "image/png" -> extractPng(bytes)
        else -> emptyList()
    }

    fun inject(encoded: ByteArray, mimeType: String, metadata: List<ByteArray>): ByteArray {
        if (metadata.isEmpty()) return encoded
        return when (mimeType) {
            "image/jpeg" -> injectJpeg(encoded, metadata)
            "image/png" -> injectPng(encoded, metadata)
            else -> encoded
        }
    }

    private fun extractJpeg(bytes: ByteArray): List<ByteArray> {
        val result = mutableListOf<ByteArray>()
        var total = 0
        var offset = 2
        while (offset + 4 <= bytes.size && bytes[offset] == 0xff.toByte()) {
            val marker = bytes[offset + 1].toInt() and 0xff
            if (marker == 0xda || marker == 0xd9) break
            val length = uint16(bytes, offset + 2)
            val segmentSize = 2 + length
            if (length < 2 || offset + segmentSize > bytes.size) break
            if (marker in setOf(0xe1, 0xe2, 0xed, 0xfe) && total + segmentSize <= maxMetadataBytes) {
                result += bytes.copyOfRange(offset, offset + segmentSize)
                total += segmentSize
            }
            offset += segmentSize
        }
        return result
    }

    private fun extractPng(bytes: ByteArray): List<ByteArray> {
        val result = mutableListOf<ByteArray>()
        var total = 0
        var offset = 8
        while (offset + 12 <= bytes.size) {
            val length = int32(bytes, offset)
            if (length < 0 || offset + 12L + length > bytes.size) break
            val chunkSize = length + 12
            val type = String(bytes, offset + 4, 4, Charsets.US_ASCII)
            if (type in pngMetadataTypes && total + chunkSize <= maxMetadataBytes) {
                result += bytes.copyOfRange(offset, offset + chunkSize)
                total += chunkSize
            }
            offset += chunkSize
            if (type == "IEND") break
        }
        return result
    }

    private fun injectJpeg(encoded: ByteArray, metadata: List<ByteArray>): ByteArray {
        if (encoded.size < 2) return encoded
        return ByteArrayOutputStream(encoded.size + metadata.sumOf { it.size }).apply {
            write(encoded, 0, 2)
            metadata.forEach { write(it) }
            write(encoded, 2, encoded.size - 2)
        }.toByteArray()
    }

    private fun injectPng(encoded: ByteArray, metadata: List<ByteArray>): ByteArray {
        if (encoded.size < 33) return encoded
        return ByteArrayOutputStream(encoded.size + metadata.sumOf { it.size }).apply {
            write(encoded, 0, 33)
            metadata.forEach { write(it) }
            write(encoded, 33, encoded.size - 33)
        }.toByteArray()
    }

    private fun uint16(bytes: ByteArray, offset: Int): Int =
        if (offset + 2 <= bytes.size) ((bytes[offset].toInt() and 0xff) shl 8) or (bytes[offset + 1].toInt() and 0xff) else -1

    private fun int32(bytes: ByteArray, offset: Int): Int =
        if (offset + 4 <= bytes.size) {
            ((bytes[offset].toInt() and 0xff) shl 24) or
                ((bytes[offset + 1].toInt() and 0xff) shl 16) or
                ((bytes[offset + 2].toInt() and 0xff) shl 8) or
                (bytes[offset + 3].toInt() and 0xff)
        } else -1
}
