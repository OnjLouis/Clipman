package me.onj.clipman

import android.content.Context
import android.net.Uri
import androidx.documentfile.provider.DocumentFile
import java.security.MessageDigest

internal class SharedFolderStorageException(message: String, cause: Throwable? = null) :
    Exception(message, cause)

internal enum class SharedFolderContentKind {
    History,
    Rules
}

internal data class SharedFolderDocument(
    val id: String,
    val name: String
)

internal interface SharedFolderDocumentBackend {
    val identity: String
    fun list(): List<SharedFolderDocument>
    fun read(document: SharedFolderDocument): ByteArray
    fun write(fileName: String, data: ByteArray)
    fun delete(document: SharedFolderDocument)
}

private class AndroidSharedFolderDocumentBackend(
    context: Context,
    private val treeUri: Uri
) : SharedFolderDocumentBackend {
    private val appContext = context.applicationContext
    override val identity: String = treeUri.toString()

    override fun list(): List<SharedFolderDocument> = tree().listFiles().mapNotNull { document ->
        val name = document.name ?: return@mapNotNull null
        SharedFolderDocument(document.uri.toString(), name)
    }

    override fun read(document: SharedFolderDocument): ByteArray =
        appContext.contentResolver.openInputStream(Uri.parse(document.id))?.use { input ->
            ClipDatabaseFile.readDatabaseBlob(input)
        } ?: throw SharedFolderStorageException(
            "The selected shared-folder file could not be opened for reading."
        )

    override fun write(fileName: String, data: ByteArray) {
        val folder = tree()
        val target = folder.listFiles().firstOrNull { it.name.equals(fileName, ignoreCase = true) }
            ?: folder.createFile(mimeType, fileName)
            ?: throw SharedFolderStorageException("The shared-folder file could not be created.")
        val resolver = appContext.contentResolver
        val output = try {
            resolver.openOutputStream(target.uri, "rwt")
                ?: resolver.openOutputStream(target.uri, "wt")
        } catch (error: Throwable) {
            if (error is SecurityException) throw error
            resolver.openOutputStream(target.uri, "wt")
        } ?: throw SharedFolderStorageException(
            "The selected shared-folder file could not be opened for writing."
        )
        output.use {
            it.write(data)
            it.flush()
        }
    }

    override fun delete(document: SharedFolderDocument) {
        DocumentFile.fromSingleUri(appContext, Uri.parse(document.id))?.delete()
    }

    private fun tree(): DocumentFile {
        val folder = DocumentFile.fromTreeUri(appContext, treeUri)
            ?: throw SharedFolderStorageException("The selected shared folder is no longer available.")
        if (!folder.canRead() || !folder.canWrite()) {
            throw SharedFolderStorageException(
                "Clipman no longer has read and write permission for the selected shared folder."
            )
        }
        return folder
    }

    companion object {
        private const val mimeType = "application/octet-stream"
    }
}

/**
 * Presents a Storage Access Framework folder through the same revisioned
 * contract used by Clipman Server. Provider-specific networking and accounts
 * remain the responsibility of Android and the selected document provider.
 */
internal class SharedFolderStorageClient private constructor(
    private val backend: SharedFolderDocumentBackend,
    private val password: String,
    private val fileName: String,
    private val contentKind: SharedFolderContentKind
) : HistoryStorageClient {
    constructor(context: Context, treeUri: String, password: String) : this(
        AndroidSharedFolderDocumentBackend(context, Uri.parse(treeUri)),
        password,
        LocalHistoryStore.coreFileName,
        SharedFolderContentKind.History
    )

    internal constructor(
        backend: SharedFolderDocumentBackend,
        password: String
    ) : this(backend, password, LocalHistoryStore.coreFileName, SharedFolderContentKind.History)

    override val isConfigured = backend.identity.isNotBlank() && password.isNotBlank()
    override val storageName = "shared folder"
    override val syncCacheIdentity: String
        get() = sha256Hex("shared-folder|${backend.identity}|$fileName|${sha256Hex(password)}")
    override val createOnlyWhenMissing = true

    override fun forChannel(channelKey: String): HistoryStorageClient? {
        if (!isConfigured || channelKey.isBlank()) return null
        return SharedFolderStorageClient(
            backend,
            password,
            LocalHistoryStore.channelFileName(channelKey),
            SharedFolderContentKind.History
        )
    }

    override fun forSyncRules(): HistoryStorageClient? {
        if (!isConfigured) return null
        return SharedFolderStorageClient(
            backend,
            password,
            syncRulesFileName,
            SharedFolderContentKind.Rules
        )
    }

    override fun metadata(): String = synchronized(ioLock) {
        val candidates = readCandidates()
        if (candidates.isEmpty()) "" else revision(candidates)
    }

    override fun download(): ServerDatabaseDownload = synchronized(ioLock) {
        val candidates = readCandidates()
        if (candidates.isEmpty()) {
            throw ServerDatabaseNotFoundException("The shared-folder database does not exist yet.")
        }
        val data = if (candidates.size == 1) candidates.first().data else merge(candidates.map { it.data })
        ServerDatabaseDownload(revision(candidates), data)
    }

    override fun upload(
        data: ByteArray,
        expectedRevision: String,
        createOnly: Boolean
    ): ServerDatabaseDownload = synchronized(ioLock) {
        requireConfigured()
        ClipDatabaseFile.requireDatabaseBlobSize(data.size.toLong())
        val candidates = readCandidates()
        if (createOnly && candidates.isNotEmpty()) {
            throw ServerConflictException("The shared-folder database was created by another device.")
        }
        if (expectedRevision.isNotBlank() && revision(candidates) != expectedRevision) {
            throw ServerConflictException("The shared-folder database changed on another device.")
        }
        backend.write(fileName, data)
        candidates
            .filterNot { it.document.name.equals(fileName, ignoreCase = true) }
            .forEach { runCatching { backend.delete(it.document) } }
        ServerDatabaseDownload(revision(listOf(Candidate(SharedFolderDocument(fileName, fileName), data))), ByteArray(0))
    }

    private fun readCandidates(): List<Candidate> {
        requireConfigured()
        return backend.list()
            .filter { document ->
                document.name.equals(fileName, ignoreCase = true) ||
                    isConflictSibling(document.name, fileName)
            }
            .map { document -> Candidate(document, backend.read(document)) }
    }

    private fun merge(payloads: List<ByteArray>): ByteArray = when (contentKind) {
        SharedFolderContentKind.History -> {
            var merged = ClipDatabase()
            payloads.forEach { data ->
                merged = SyncConflictResolver.merge(merged, ClipDatabaseFile.load(data, password))
            }
            ClipDatabaseFile.save(
                merged,
                password,
                preferredSalt = payloads.firstNotNullOfOrNull(ClipDatabaseFile::encryptedSalt)
            )
        }
        SharedFolderContentKind.Rules -> {
            var merged: SyncRulesDocument? = null
            payloads.forEach { data ->
                val document = SyncRuleEngine.parse(ClipDatabaseFile.loadRawText(data, password))
                    ?: throw SharedFolderStorageException("The shared sync-rules file could not be decoded.")
                merged = SyncRuleEngine.mergeDocuments(merged, document)
            }
            val document = merged
                ?: throw SharedFolderStorageException("The shared sync-rules file could not be decoded.")
            ClipDatabaseFile.saveRawText(
                SyncRuleEngine.serialize(document),
                password,
                preferredSalt = payloads.firstNotNullOfOrNull(ClipDatabaseFile::encryptedSalt)
            )
        }
    }

    private fun requireConfigured() {
        if (password.isBlank()) {
            throw SharedFolderStorageException("Shared folder sync requires a nonblank history password.")
        }
        if (backend.identity.isBlank()) {
            throw SharedFolderStorageException("Choose a shared folder in Settings.")
        }
    }

    private data class Candidate(
        val document: SharedFolderDocument,
        val data: ByteArray
    )

    companion object {
        private const val syncRulesFileName = "clipman-sync-rules.clipdb"
        private val ioLock = Any()

        private fun revision(candidates: List<Candidate>): String {
            val hashes = candidates.map { sha256Hex(it.data) }.sorted()
            return sha256Hex(hashes.joinToString("|"))
        }

        private fun sha256Hex(value: String): String = sha256Hex(value.toByteArray(Charsets.UTF_8))

        private fun sha256Hex(value: ByteArray): String =
            MessageDigest.getInstance("SHA-256")
                .digest(value)
                .joinToString("") { "%02x".format(it) }

        internal fun isConflictSibling(candidate: String, canonical: String): Boolean {
            val extension = canonical.substringAfterLast('.', "")
            val base = canonical.removeSuffix(if (extension.isEmpty()) "" else ".$extension")
            if (!candidate.endsWith(if (extension.isEmpty()) "" else ".$extension", ignoreCase = true)) return false
            val candidateBase = candidate.removeSuffix(if (extension.isEmpty()) "" else ".${candidate.substringAfterLast('.')}")
            if (!candidateBase.startsWith(base, ignoreCase = true) || candidateBase.equals(base, ignoreCase = true)) {
                return false
            }
            val suffix = candidateBase.drop(base.length).lowercase()
            if (suffix.contains("conflicted copy") || suffix.contains("[conflict]") || suffix.contains(" conflict")) {
                return true
            }
            if (suffix.startsWith("_conf(") || suffix.startsWith(" _conf(")) return true
            return suffix.matches(Regex("""\s*[\[(]\d+[\])]\s*"""))
        }
    }
}
