package me.onj.clipman

import android.content.ClipData
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.core.content.FileProvider
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.UUID

data class SavedImageResult(val uri: Uri, val displayName: String)

internal object AndroidImageEntryActionPolicy {
    const val saveToPhotosLabel = "Save to Photos"
    const val shareLabel = "Share"
    private val genericImageName = Regex("(?i)^(?:clipboard|clipman)[ _-]*image(?:[ _-]*\\d+)?\\.(?:png|jpe?g)$")
    private val unsafeFilenameCharacters = Regex("[^A-Za-z0-9._ -]")

    fun exportFilename(image: EmbeddedImageData, sourceDevice: String, createdUnixMs: Long): String {
        validateImage(image)
        val extension = EmbeddedImageRichText.extensionFor(image.mimeType)
        val normalized = EmbeddedImageRichText.normalizeFilename(image.filename, image.mimeType)
        if (!genericImageName.matches(normalized)) return normalized

        val timestamp = SimpleDateFormat("yyyy-MM-dd HH-mm-ss", Locale.US).apply {
            timeZone = TimeZone.getDefault()
        }.format(Date(createdUnixMs.takeIf { it > 0 } ?: System.currentTimeMillis()))
        val device = sourceDevice
            .replace(unsafeFilenameCharacters, "_")
            .trim(' ', '.', '_')
            .take(48)
        val suffix = device.takeIf { it.isNotBlank() }?.let { " - $it" }.orEmpty()
        return "Clipman image $timestamp$suffix.$extension"
    }

    fun validateImage(image: EmbeddedImageData) {
        require(image.mimeType == "image/png" || image.mimeType == "image/jpeg") {
            "Only embedded PNG and JPEG images can be exported."
        }
        val inspected = EncodedImageInspector.inspect(image.bytes)
        require(inspected != null && inspected.mimeType == image.mimeType) {
            "The stored image data is invalid."
        }
    }
}

object AndroidImageEntryActions {
    private const val shareRetentionMs = 24L * 60L * 60L * 1000L

    fun saveToPhotos(
        context: Context,
        image: EmbeddedImageData,
        sourceDevice: String,
        createdUnixMs: Long
    ): SavedImageResult {
        AndroidImageEntryActionPolicy.validateImage(image)
        val displayName = AndroidImageEntryActionPolicy.exportFilename(image, sourceDevice, createdUnixMs)
        val resolver = context.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, displayName)
            put(MediaStore.Images.Media.MIME_TYPE, image.mimeType)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                put(MediaStore.Images.Media.RELATIVE_PATH, Environment.DIRECTORY_PICTURES + "/Clipman")
                put(MediaStore.Images.Media.IS_PENDING, 1)
            }
        }
        val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
            ?: throw ImageClipboardException("Android could not create the image in Photos.")
        try {
            resolver.openOutputStream(uri, "w")?.use { output ->
                output.write(image.bytes)
                output.flush()
            } ?: throw ImageClipboardException("Android could not write the image to Photos.")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                resolver.update(uri, ContentValues().apply {
                    put(MediaStore.Images.Media.IS_PENDING, 0)
                }, null, null)
            }
            return SavedImageResult(uri, displayName)
        } catch (error: Throwable) {
            runCatching { resolver.delete(uri, null, null) }
            throw error
        }
    }

    fun createShareChooser(
        context: Context,
        image: EmbeddedImageData,
        sourceDevice: String,
        createdUnixMs: Long
    ): Intent {
        AndroidImageEntryActionPolicy.validateImage(image)
        val displayName = AndroidImageEntryActionPolicy.exportFilename(image, sourceDevice, createdUnixMs)
        val root = File(context.cacheDir, "shared-images")
        check(root.exists() || root.mkdirs()) { "Could not prepare the image for sharing." }
        val cutoff = System.currentTimeMillis() - shareRetentionMs
        root.listFiles()?.filter { it.lastModified() < cutoff }?.forEach { it.deleteRecursively() }

        val directory = File(root, UUID.randomUUID().toString())
        check(directory.mkdir()) { "Could not prepare the image for sharing." }
        val file = File(directory, displayName)
        try {
            file.writeBytes(image.bytes)
            val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
            val send = Intent(Intent.ACTION_SEND).apply {
                type = image.mimeType
                putExtra(Intent.EXTRA_STREAM, uri)
                clipData = ClipData.newUri(context.contentResolver, "Clipman image", uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            return Intent.createChooser(send, "Share image").apply {
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
        } catch (error: Throwable) {
            directory.deleteRecursively()
            throw error
        }
    }
}
