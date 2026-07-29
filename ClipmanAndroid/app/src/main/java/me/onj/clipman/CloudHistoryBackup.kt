package me.onj.clipman

import android.content.Context
import android.net.Uri
import androidx.documentfile.provider.DocumentFile

data class CloudBackupOptions(
    val enabled: Boolean,
    val treeUri: String
)

object CloudHistoryBackup {
    const val fileName = "Clipman History.clipdb"
    private const val mimeType = "application/octet-stream"
    private const val maximumBackupBytes = 128 * 1024 * 1024

    fun write(context: Context, bytes: ByteArray, options: CloudBackupOptions): String? {
        if (!options.enabled) return null
        if (options.treeUri.isBlank()) return "Choose a backup folder in Settings."
        if (!ClipDatabaseFile.isEncrypted(bytes)) {
            return "Cloud history backups require a nonblank history password."
        }
        return runCatching {
            val tree = DocumentFile.fromTreeUri(context, Uri.parse(options.treeUri))
                ?: error("The selected backup folder is no longer available.")
            check(tree.canWrite()) { "Clipman no longer has permission to write to the selected backup folder." }
            val target = tree.findFile(fileName) ?: tree.createFile(mimeType, fileName)
                ?: error("The backup file could not be created.")
            context.contentResolver.openOutputStream(target.uri, "wt")?.use { output ->
                output.write(bytes)
                output.flush()
            } ?: error("The backup file could not be opened for writing.")
        }.exceptionOrNull()?.let { it.message ?: it::class.java.simpleName }
    }

    fun read(context: Context, uri: Uri, password: String): ClipDatabase {
        require(password.isNotEmpty()) { "Set and save a history password before restoring a cloud backup." }
        val bytes = context.contentResolver.openInputStream(uri)?.use { input ->
            val output = java.io.ByteArrayOutputStream()
            val buffer = ByteArray(16 * 1024)
            var total = 0
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                total += count
                require(total <= maximumBackupBytes) { "This history backup is too large." }
                output.write(buffer, 0, count)
            }
            output.toByteArray()
        } ?: error("The selected history backup could not be read.")
        require(ClipDatabaseFile.isEncrypted(bytes)) {
            "Cloud history backups must be encrypted with a nonblank history password."
        }
        return ClipDatabaseFile.load(bytes, password)
    }

    fun locationName(context: Context, treeUri: Uri): String =
        DocumentFile.fromTreeUri(context, treeUri)?.name?.takeIf { it.isNotBlank() }
            ?: "Selected folder"
}
