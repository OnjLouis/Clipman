package me.onj.clipman

import android.content.Context
import android.util.AtomicFile
import java.io.File

class LocalHistoryStore(context: Context) {
    private val atomicFile = AtomicFile(File(context.filesDir, "clipman-history.clipdb"))

    fun load(password: String): ClipDatabase? {
        if (!atomicFile.baseFile.exists()) return null
        val bytes = atomicFile.openRead().use { input ->
            ClipDatabaseFile.readDatabaseBlob(input, atomicFile.baseFile.length())
        }
        return ClipDatabaseFile.load(bytes, password)
    }

    fun save(database: ClipDatabase, password: String) {
        saveBytes(ClipDatabaseFile.save(database, password))
    }

    fun saveBytes(bytes: ByteArray) {
        ClipDatabaseFile.requireDatabaseBlobSize(bytes.size.toLong())
        val output = atomicFile.startWrite()
        try {
            output.write(bytes)
            output.fd.sync()
            atomicFile.finishWrite(output)
        } catch (error: Throwable) {
            atomicFile.failWrite(output)
            throw error
        }
    }
}

data class MobileSyncResult(
    val database: ClipDatabase,
    val revision: String,
    val uploaded: Boolean,
    val pendingError: String? = null,
    val backupError: String? = null
)

class MobileHistoryRepository(context: Context) {
    private val appContext = context.applicationContext
    private val localStore = LocalHistoryStore(context)

    fun loadLocal(password: String): ClipDatabase {
        val existing = localStore.load(password)
        if (existing != null) return existing
        val empty = ClipDatabase()
        localStore.save(empty, password)
        return empty
    }

    fun loadLocalOrNull(password: String): ClipDatabase? = localStore.load(password)

    fun saveLocal(
        database: ClipDatabase,
        password: String,
        backupOptions: CloudBackupOptions = CloudBackupOptions(false, "")
    ): String? {
        val bytes = ClipDatabaseFile.save(database, password)
        localStore.saveBytes(bytes)
        if (!backupOptions.enabled) return null
        if (password.isEmpty()) return "Set a nonblank history password before enabling cloud backup."
        return CloudHistoryBackup.write(appContext, bytes, backupOptions)
    }

    fun synchronize(
        serverUrl: String,
        token: String,
        password: String,
        serverCaCertPem: String,
        serverCaHost: String,
        current: ClipDatabase,
        backupOptions: CloudBackupOptions = CloudBackupOptions(false, ""),
        localAlreadySaved: Boolean = false
    ): MobileSyncResult {
        val cached = if (localAlreadySaved) current else localStore.load(password)
        val local = if (localAlreadySaved) {
            current
        } else {
            cached?.let { SyncConflictResolver.merge(target = current, source = it) } ?: current
        }
        val client = ServerStorageClient(serverUrl, token, password, serverCaCertPem, serverCaHost)
        var remoteDownload = try {
            client.download()
        } catch (_: ServerDatabaseNotFoundException) {
            val encoded = ClipDatabaseFile.save(local, password)
            val uploaded = client.upload(encoded, "")
            val backupError = if (cached == null || !SyncConflictResolver.hasSameContent(local, cached)) {
                saveLocal(local, password, backupOptions)
            } else null
            return MobileSyncResult(local, uploaded.revision, true, backupError = backupError)
        }

        repeat(3) { attempt ->
            val remote = ClipDatabaseFile.load(remoteDownload.data, password)
            val merged = SyncConflictResolver.merge(target = local, source = remote)
            val needsUpload = !SyncConflictResolver.hasSameContent(merged, remote)
            if (!needsUpload) {
                val backupError = if (cached == null || !SyncConflictResolver.hasSameContent(merged, cached)) {
                    saveLocal(merged, password, backupOptions)
                } else null
                return MobileSyncResult(merged, remoteDownload.revision, false, backupError = backupError)
            }
            try {
                val uploaded = client.upload(ClipDatabaseFile.save(merged, password), remoteDownload.revision)
                val backupError = if (cached == null || !SyncConflictResolver.hasSameContent(merged, cached)) {
                    saveLocal(merged, password, backupOptions)
                } else null
                return MobileSyncResult(merged, uploaded.revision, true, backupError = backupError)
            } catch (error: ServerConflictException) {
                if (attempt == 2) throw error
                remoteDownload = client.download()
            }
        }
        error("Clipman Server synchronization did not complete.")
    }
}
