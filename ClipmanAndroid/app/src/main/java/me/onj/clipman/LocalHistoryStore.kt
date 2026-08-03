package me.onj.clipman

import android.content.Context
import android.util.AtomicFile
import java.io.File

class LocalHistoryStore(context: Context) {
    private val atomicFile = AtomicFile(File(context.filesDir, "clipman-history.clipdb"))
    private var encryptedSalt: ByteArray? = null

    fun load(password: String): ClipDatabase? {
        if (!atomicFile.baseFile.exists()) return null
        val bytes = atomicFile.openRead().use { input ->
            ClipDatabaseFile.readDatabaseBlob(input, atomicFile.baseFile.length())
        }
        encryptedSalt = ClipDatabaseFile.encryptedSalt(bytes)
        return ClipDatabaseFile.load(bytes, password)
    }

    fun save(database: ClipDatabase, password: String) {
        saveBytes(encode(database, password))
    }

    fun encode(database: ClipDatabase, password: String): ByteArray =
        ClipDatabaseFile.save(database, password, preferredSalt = encryptedSalt)

    fun saveBytes(bytes: ByteArray) {
        ClipDatabaseFile.requireDatabaseBlobSize(bytes.size.toLong())
        val output = atomicFile.startWrite()
        try {
            output.write(bytes)
            output.fd.sync()
            atomicFile.finishWrite(output)
            encryptedSalt = ClipDatabaseFile.encryptedSalt(bytes)
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

class MobileMutationException(
    cause: Throwable,
    val localSaved: Boolean
) : Exception(cause.message, cause)

internal fun <T> runMutationUpload(
    expectedRevision: String,
    directUpload: () -> T,
    conflictFallback: () -> T
): T {
    if (expectedRevision.isBlank()) return conflictFallback()
    return try {
        directUpload()
    } catch (_: ServerConflictException) {
        conflictFallback()
    } catch (_: ServerDatabaseNotFoundException) {
        conflictFallback()
    }
}

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
        val bytes = localStore.encode(database, password)
        return saveEncodedLocal(bytes, password, backupOptions)
    }

    private fun saveEncodedLocal(
        bytes: ByteArray,
        password: String,
        backupOptions: CloudBackupOptions
    ): String? {
        localStore.saveBytes(bytes)
        if (!backupOptions.enabled) return null
        if (password.isEmpty()) return "Set a nonblank history password before enabling cloud backup."
        return CloudHistoryBackup.write(appContext, bytes, backupOptions)
    }

    fun persistMutation(
        serverUrl: String,
        token: String,
        password: String,
        serverCaCertPem: String,
        serverCaHost: String,
        current: ClipDatabase,
        expectedRevision: String,
        backupOptions: CloudBackupOptions = CloudBackupOptions(false, "")
    ): MobileSyncResult {
        val encoded: ByteArray
        val backupError: String?
        try {
            encoded = localStore.encode(current, password)
            backupError = saveEncodedLocal(encoded, password, backupOptions)
        } catch (error: Throwable) {
            throw MobileMutationException(error, localSaved = false)
        }

        val client = ServerStorageClient(serverUrl, token, password, serverCaCertPem, serverCaHost)
        return try {
            runMutationUpload(
                expectedRevision = expectedRevision,
                directUpload = {
                    val uploaded = client.upload(encoded, expectedRevision)
                    MobileSyncResult(
                        database = current,
                        revision = uploaded.revision,
                        uploaded = true,
                        backupError = backupError
                    )
                },
                conflictFallback = {
                    val sync = synchronize(
                        serverUrl = serverUrl,
                        token = token,
                        password = password,
                        serverCaCertPem = serverCaCertPem,
                        serverCaHost = serverCaHost,
                        current = current,
                        backupOptions = backupOptions,
                        localAlreadySaved = true
                    )
                    if (sync.backupError == null && backupError != null) {
                        sync.copy(backupError = backupError)
                    } else {
                        sync
                    }
                }
            )
        } catch (error: Throwable) {
            throw MobileMutationException(error, localSaved = true)
        }
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
        val remoteDownload = try {
            client.download()
        } catch (_: ServerDatabaseNotFoundException) {
            val encoded = localStore.encode(local, password)
            val uploaded = client.upload(encoded, "")
            val backupError = if (cached == null || !SyncConflictResolver.hasSameContent(local, cached)) {
                saveLocal(local, password, backupOptions)
            } else null
            return MobileSyncResult(local, uploaded.revision, true, backupError = backupError)
        }

        val remote = ClipDatabaseFile.load(remoteDownload.data, password)
        val merged = SyncConflictResolver.merge(target = local, source = remote)
        val needsUpload = !SyncConflictResolver.hasSameContent(merged, remote)
        if (!needsUpload) {
            val backupError = if (cached == null || !SyncConflictResolver.hasSameContent(merged, cached)) {
                saveLocal(merged, password, backupOptions)
            } else null
            return MobileSyncResult(merged, remoteDownload.revision, false, backupError = backupError)
        }
        val uploaded = client.upload(localStore.encode(merged, password), remoteDownload.revision)
        val backupError = if (cached == null || !SyncConflictResolver.hasSameContent(merged, cached)) {
            saveLocal(merged, password, backupOptions)
        } else null
        return MobileSyncResult(merged, uploaded.revision, true, backupError = backupError)
    }
}
