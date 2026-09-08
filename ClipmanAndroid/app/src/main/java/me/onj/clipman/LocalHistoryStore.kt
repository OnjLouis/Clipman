package me.onj.clipman

import android.content.Context
import android.util.AtomicFile
import java.io.File
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

class LocalHistoryStore(context: Context, fileName: String = "clipman-history.clipdb") {
    private val atomicFile = AtomicFile(File(context.filesDir, fileName))
    private var encryptedSalt: ByteArray? = null

    /** The PBKDF2 salt of the container this store last read or wrote. */
    val salt: ByteArray?
        get() = encryptedSalt

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

    /**
     * Reads only this container's PBKDF2 salt, so the salt every other bucket
     * copies can be recovered without decrypting the whole history.
     */
    fun peekSalt(): ByteArray? {
        if (!atomicFile.baseFile.exists()) return null
        val header = ByteArray(24)
        var offset = 0
        atomicFile.openRead().use { input ->
            while (offset < header.size) {
                val count = input.read(header, offset, header.size - offset)
                if (count < 0) break
                offset += count
            }
        }
        if (offset < header.size) return null
        encryptedSalt = ClipDatabaseFile.encryptedSalt(header)
        return encryptedSalt
    }

    /**
     * Adopts the core database's salt so a channel file created for the first
     * time shares one PBKDF2 derivation with the history database
     * (sync-rules-spec.md section 5, Salt sharing).
     */
    fun adoptSalt(value: ByteArray?) {
        if (encryptedSalt == null && value != null && value.size == 16) encryptedSalt = value.copyOf()
    }

    companion object {
        const val coreFileName = "clipman-history.clipdb"

        /** The sibling file that caches one channel (spec section 2). */
        fun channelFileName(channelKey: String): String =
            "clipman-channel-${SyncRuleEngine.channelStorageName(channelKey)}.clipdb"
    }
}

data class MobileSyncResult(
    val database: ClipDatabase,
    val revision: String,
    val uploaded: Boolean,
    val pendingError: String? = null,
    val backupError: String? = null,
    val writeThroughMessage: String? = null
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

/**
 * One channel bucket as it stood at the last transfer. The key is "" for the
 * core channel. [plainHash] is the durable plaintext hash of [database] and is
 * what dirty detection compares against, because ciphertext differs on every
 * encode (sync-rules-spec.md section 5, upload step 4).
 */
data class MobileChannelState(
    val key: String,
    val revision: String = "",
    val plainHash: String = "",
    val database: ClipDatabase = ClipDatabase(),
    val exists: Boolean = false,
    val salt: ByteArray? = null
)

/** The merged view across channels and the channel each entry was loaded from. */
data class MobileChannelAssembly(
    val view: ClipDatabase,
    val residence: Map<String, String>
)

/** The outcome of a channel-aware save. */
data class MobileChannelCommit(
    val channels: List<MobileChannelState>,
    val view: ClipDatabase,
    val residence: Map<String, String>,
    val uploads: Int,
    val delivered: List<String>,
    val pending: Map<String, List<ClipEntry>>,
    val committed: Boolean,
    val failure: Throwable?
)

/** What the rules screen shows for this device. */
data class MobileSyncRulesSnapshot(
    val document: SyncRulesDocument?,
    val readOnly: Boolean,
    val subscribesToAll: Boolean,
    val subscribedKeys: List<String>,
    val registered: Boolean,
    val pendingChannelKeys: List<String>
)

internal data class MobileChannelFetch(
    val database: ClipDatabase,
    val revision: String,
    val salt: ByteArray?
)

internal data class MobileChannelWriteResult(
    val revision: String,
    val salt: ByteArray?
)

/**
 * The channel bucket operations the engine needs. Splitting them out keeps the
 * two-phase upload ordering testable without a server or an Android context.
 */
internal interface MobileChannelTransport {
    /** The bucket's current revision, or "" when it does not exist. */
    fun revision(channelKey: String): String

    /** The bucket's stored database, or null when it does not exist. */
    fun read(channelKey: String): MobileChannelFetch?

    fun write(
        channelKey: String,
        database: ClipDatabase,
        expectedRevision: String,
        exists: Boolean
    ): MobileChannelWriteResult
}

internal class ServerChannelTransport(
    private val client: ServerStorageClient,
    private val password: String
) : MobileChannelTransport {
    private val salts = HashMap<String, ByteArray?>()
    private var coreSaltValue: ByteArray? = null

    val coreSalt: ByteArray?
        get() = coreSaltValue

    fun seedCoreSalt(value: ByteArray?) {
        if (coreSaltValue == null && value != null && value.size == 16) coreSaltValue = value.copyOf()
    }

    private fun clientFor(channelKey: String): ServerStorageClient {
        if (channelKey.isEmpty()) return client
        return client.forChannel(channelKey)
            ?: throw IllegalStateException(
                "The \"$channelKey\" channel needs a Clipman Server token and a history password."
            )
    }

    override fun revision(channelKey: String): String = clientFor(channelKey).metadata()

    override fun read(channelKey: String): MobileChannelFetch? {
        val download = try {
            clientFor(channelKey).download()
        } catch (_: ServerDatabaseNotFoundException) {
            return null
        }
        val salt = ClipDatabaseFile.encryptedSalt(download.data)
        salts[channelKey] = salt
        if (channelKey.isEmpty()) seedCoreSalt(salt)
        return MobileChannelFetch(ClipDatabaseFile.load(download.data, password), download.revision, salt)
    }

    override fun write(
        channelKey: String,
        database: ClipDatabase,
        expectedRevision: String,
        exists: Boolean
    ): MobileChannelWriteResult {
        val encoded = ClipDatabaseFile.save(database, password, preferredSalt = salts[channelKey] ?: coreSaltValue)
        val uploaded = clientFor(channelKey).upload(encoded, if (exists) expectedRevision else "")
        val salt = ClipDatabaseFile.encryptedSalt(encoded)
        salts[channelKey] = salt
        if (channelKey.isEmpty()) seedCoreSalt(salt)
        return MobileChannelWriteResult(uploaded.revision, salt)
    }
}

/**
 * The multi-channel sync algorithm of sync-rules-spec.md section 5, mirroring
 * ClipmanCli/internal/syncengine/channels.go: id-keyed cross-channel assembly,
 * channel-local tombstones, and the add-then-remove two-phase upload.
 */
internal object MobileChannelEngine {
    private const val uploadRetries = 3

    /**
     * Merges the per-channel databases into the single view the user sees
     * (download steps 3 and 4) and records which channel each surviving entry
     * came from. Core must be first, then channels in rules-document order.
     */
    fun buildView(channels: List<MobileChannelState>): MobileChannelAssembly {
        var version = 1
        val entries = mutableListOf<ClipEntry>()
        val owners = mutableListOf<String>()
        val indexById = HashMap<String, Int>()

        for (state in channels) {
            if (state.database.Version > version) version = state.database.Version
            for (entry in state.database.Entries) {
                val identifier = comparableClipId(entry.Id)
                val existing = if (identifier.isEmpty()) null else indexById[identifier]
                if (existing != null) {
                    // The same id in two channels is a move race: the copy with
                    // the higher ModifiedUnixMs wins, so a tie keeps the copy
                    // from the earlier channel in assembly order.
                    if (entry.ModifiedUnixMs > entries[existing].ModifiedUnixMs) {
                        entries[existing] = entry
                        owners[existing] = state.key
                    }
                    continue
                }
                entries.add(entry)
                owners.add(state.key)
                if (identifier.isNotEmpty()) indexById[identifier] = entries.size - 1
            }
        }

        // Tombstones apply within their own channel only, with one exception: a
        // marker with a non-empty TextHash also suppresses matching-text entries
        // in other channels. A relocation marker has an empty TextHash and so
        // never suppresses a live entry that merely moved.
        val suppressed = BooleanArray(entries.size)
        for (state in channels) {
            for (marker in state.database.DeletedEntries) {
                if (marker.TextHash.isEmpty()) continue
                for (index in entries.indices) {
                    if (suppressed[index] || owners[index] == state.key) continue
                    if (textMarkerSuppresses(marker, entries[index])) suppressed[index] = true
                }
            }
        }

        val kept = mutableListOf<ClipEntry>()
        val residence = HashMap<String, String>()
        val live = HashSet<String>()
        for (index in entries.indices) {
            if (suppressed[index]) continue
            kept.add(entries[index])
            residence[entries[index].Id] = owners[index]
            live.add(comparableClipId(entries[index].Id))
        }

        // The view carries every channel's markers except those contradicted by
        // a live entry elsewhere: a relocation marker names an id that now lives
        // in another channel, and applying it would delete what it only moved.
        val deleted = mutableListOf<DeletedClipEntry>()
        for (state in channels) {
            for (marker in state.database.DeletedEntries) {
                if (live.contains(comparableClipId(marker.Id))) continue
                deleted.add(marker)
            }
        }

        val view = SyncConflictResolver.normalized(
            ClipDatabase(Version = maxOf(1, version), Entries = kept, DeletedEntries = deleted)
        )
        val finalResidence = HashMap<String, String>(view.Entries.size)
        for (entry in view.Entries) {
            residence[entry.Id]?.let { finalResidence[entry.Id] = it }
        }
        return MobileChannelAssembly(view, finalResidence)
    }

    /**
     * The per-channel content a save intends to leave behind once every upload
     * has committed. It is written to the local caches before the uploads
     * start, so an offline save is never lost.
     */
    fun planChannelDatabases(
        document: SyncRulesDocument?,
        channels: List<MobileChannelState>,
        residence: Map<String, String>,
        previousMarkers: Map<String, DeletedClipEntry>,
        mutated: ClipDatabase,
        deviceName: String,
        now: Long
    ): List<ClipDatabase> {
        val routing = route(document, channels, residence, mutated, deviceName, now)
        return buildChannelDatabases(
            channels,
            routing.routed,
            assembleMarkers(channels, residence, mutated.DeletedEntries, previousMarkers, routing.subscribed, routing.relocations),
            now
        )
    }

    /**
     * Commits a mutated view: re-routes every entry, rebuilds one database per
     * channel, writes entries bound for unsubscribed channels straight through,
     * and uploads only the channels whose plaintext actually changed.
     *
     * Uploads follow the add-then-remove two-phase order of upload step 5.
     * Phase one uploads every channel while still including the entries that
     * are leaving it and withholding its new relocation markers, so targets
     * gain before sources lose; a departing entry is carried in the copy the
     * channel was fetched with, so a channel whose only change is a departure
     * is usually byte-identical to the server's copy and skips its phase-one
     * upload. Phase two rewrites only the losing channels, without their
     * departures, once every addition has committed.
     *
     * The returned commit never claims success for a failed upload: [committed]
     * is false whenever a subscribed channel could not be written.
     */
    fun commit(
        transport: MobileChannelTransport,
        document: SyncRulesDocument?,
        base: List<MobileChannelState>,
        residence: Map<String, String>,
        previousMarkers: Map<String, DeletedClipEntry>,
        mutated: ClipDatabase,
        deviceName: String,
        now: Long
    ): MobileChannelCommit {
        val channels = base.toMutableList()
        val routing = route(document, channels, residence, mutated, deviceName, now)
        val routed = routing.routed
        val departures = routing.departures
        val relocations = routing.relocations
        val subscribed = routing.subscribed
        val downloaded = channels.associate { state ->
            state.key to state.database.Entries.associateBy { comparableClipId(it.Id) }
        }
        var uploads = 0
        val failures = LinkedHashMap<String, List<ClipEntry>>()
        val delivered = mutableListOf<String>()
        var writeThroughFailure: Throwable? = null

        // The result an error is reported with. Entries that could not be
        // written through must reach the caller even when a later upload fails,
        // but the caller is told through committed whether the rest of the save
        // survived: it is false only when a subscribed channel upload failed.
        fun finish(cause: Throwable?): MobileChannelCommit {
            val assembly = buildView(channels)
            return MobileChannelCommit(
                channels = channels.toList(),
                view = assembly.view,
                residence = assembly.residence,
                uploads = uploads,
                delivered = delivered.toList(),
                pending = LinkedHashMap(failures),
                committed = cause == null,
                failure = cause ?: writeThroughFailure
            )
        }

        // First sync: create the core bucket before anything else so every other
        // bucket, channels and rules alike, copies its salt and one PBKDF2
        // derivation serves them all.
        if (!channels[0].exists) {
            val first = buildChannelDatabases(
                channels,
                withDepartures(routed, departures, downloaded),
                assembleMarkers(channels, residence, mutated.DeletedEntries, previousMarkers, subscribed, null),
                now
            )
            var writes = routing.pending.isNotEmpty()
            for (index in channels.indices) {
                if (SyncRuleEngine.durablePlainHash(first[index]) != channels[index].plainHash) writes = true
            }
            if (writes) {
                try {
                    channels[0] = putChannel(transport, channels[0], first[0])
                    uploads += 1
                } catch (error: Throwable) {
                    return finish(error)
                }
            }
        }

        // Write-through (spec section 6) is committed next: its targets gain
        // entries that their source channels are about to lose. When one fails,
        // the entry is not taken away from where it already lives - it stays in
        // its source channel and its relocation marker is cancelled - and the
        // caller is handed the entries that have nowhere to live yet.
        for (key in routing.pending.keys.sorted()) {
            val entries = routing.pending.getValue(key)
            try {
                deliver(transport, key, entries)
                delivered.add(key)
                uploads += 1
            } catch (error: Throwable) {
                if (writeThroughFailure == null) writeThroughFailure = error
                failures[key] = entries
                for (entry in entries) {
                    val source = residence[entry.Id] ?: continue
                    routed.getOrPut(source) { mutableListOf() }.add(entry)
                    departures[source]?.removeAll { comparableClipId(it.Id) == comparableClipId(entry.Id) }
                    relocations[source]?.removeAll { comparableClipId(it.Id) == comparableClipId(entry.Id) }
                }
            }
        }

        // Phase one: every channel keeps the entries it is about to lose and
        // withholds its new relocation markers, so this pass only ever adds.
        val phaseOne = buildChannelDatabases(
            channels,
            withDepartures(routed, departures, downloaded),
            assembleMarkers(channels, residence, mutated.DeletedEntries, previousMarkers, subscribed, null),
            now
        )
        for (index in channels.indices) {
            if (SyncRuleEngine.durablePlainHash(phaseOne[index]) == channels[index].plainHash) continue
            try {
                channels[index] = putChannel(transport, channels[index], phaseOne[index])
                uploads += 1
            } catch (error: Throwable) {
                return finish(joinFailures(writeThroughFailure, error))
            }
        }

        // Phase two: with every addition committed, the losing channels drop
        // their departures and gain their relocation markers.
        val phaseTwo = buildChannelDatabases(
            channels,
            routed,
            assembleMarkers(channels, residence, mutated.DeletedEntries, previousMarkers, subscribed, relocations),
            now
        )
        for (index in channels.indices) {
            if (departures[channels[index].key].isNullOrEmpty()) continue
            if (SyncRuleEngine.durablePlainHash(phaseTwo[index]) == channels[index].plainHash) continue
            try {
                channels[index] = putChannel(transport, channels[index], phaseTwo[index])
                uploads += 1
            } catch (error: Throwable) {
                return finish(joinFailures(writeThroughFailure, error))
            }
        }

        return finish(null)
    }

    /**
     * The one-shot fetch-merge-put of spec section 6 for a channel this device
     * does not subscribe to. The channel is discarded again afterwards, so its
     * contents never reach the local view.
     */
    fun deliver(transport: MobileChannelTransport, channelKey: String, entries: List<ClipEntry>) {
        val fetch = transport.read(channelKey)
        val existing = SyncConflictResolver.normalized(fetch?.database ?: ClipDatabase())
        val state = MobileChannelState(
            key = channelKey,
            revision = fetch?.revision ?: "",
            plainHash = SyncRuleEngine.durablePlainHash(existing),
            database = existing,
            exists = fetch != null,
            salt = fetch?.salt
        )
        val trimmed = existing.copy(DeletedEntries = dropMarkersForEntries(existing.DeletedEntries, entries))
        val merged = SyncConflictResolver.merge(target = trimmed, source = ClipDatabase(Entries = entries))
        putChannel(transport, state, merged)
    }

    private class Routing(
        val routed: HashMap<String, MutableList<ClipEntry>>,
        val departures: HashMap<String, MutableList<ClipEntry>>,
        val relocations: HashMap<String, MutableList<DeletedClipEntry>>,
        val pending: LinkedHashMap<String, MutableList<ClipEntry>>,
        val subscribed: Set<String>
    )

    /**
     * Upload steps 1 to 3: assign every entry to the channel its route names,
     * and leave a relocation tombstone behind in the channel it came from. The
     * empty TextHash is what distinguishes "moved" from "deleted".
     */
    private fun route(
        document: SyncRulesDocument?,
        channels: List<MobileChannelState>,
        residence: Map<String, String>,
        mutated: ClipDatabase,
        deviceName: String,
        now: Long
    ): Routing {
        val subscribed = channels.map { it.key }.toSet()
        val routed = HashMap<String, MutableList<ClipEntry>>()
        val departures = HashMap<String, MutableList<ClipEntry>>()
        val relocations = HashMap<String, MutableList<DeletedClipEntry>>()
        val pending = LinkedHashMap<String, MutableList<ClipEntry>>()

        for (entry in mutated.Entries) {
            val target = SyncRuleEngine.routeEntry(document, entry)
            val source = residence[entry.Id]
            if (source != null && source != target) {
                departures.getOrPut(source) { mutableListOf() }.add(entry)
                relocations.getOrPut(source) { mutableListOf() }.add(
                    DeletedClipEntry(
                        Id = entry.Id,
                        TextHash = "",
                        DeletedUnixMs = now,
                        SourceMachine = deviceName
                    )
                )
            }
            if (subscribed.contains(target)) {
                routed.getOrPut(target) { mutableListOf() }.add(entry)
            } else {
                pending.getOrPut(target) { mutableListOf() }.add(entry)
            }
        }

        return Routing(routed, departures, relocations, pending, subscribed)
    }

    /**
     * Files tombstones per channel. Each channel keeps the markers it already
     * carried; only markers this save created or refreshed are filed against
     * the channel the entry lived in, and relocation markers are added last.
     */
    private fun assembleMarkers(
        channels: List<MobileChannelState>,
        residence: Map<String, String>,
        viewMarkers: List<DeletedClipEntry>,
        previous: Map<String, DeletedClipEntry>,
        subscribed: Set<String>,
        relocations: Map<String, List<DeletedClipEntry>>?
    ): Map<String, List<DeletedClipEntry>> {
        val markers = HashMap<String, MutableList<DeletedClipEntry>>()
        for (state in channels) markers[state.key] = state.database.DeletedEntries.toMutableList()

        for (marker in viewMarkers) {
            val before = previous[comparableClipId(marker.Id)]
            if (before != null &&
                before.DeletedUnixMs == marker.DeletedUnixMs &&
                before.TextHash == marker.TextHash
            ) {
                continue
            }
            var home = residence[marker.Id] ?: ""
            if (!subscribed.contains(home)) home = ""
            markers.getOrPut(home) { mutableListOf() }.add(marker)
        }

        relocations?.forEach { (key, relocated) ->
            if (subscribed.contains(key)) markers.getOrPut(key) { mutableListOf() }.addAll(relocated)
        }
        return markers
    }

    /** Rebuilds one database per channel, in assembly order. */
    private fun buildChannelDatabases(
        channels: List<MobileChannelState>,
        routed: Map<String, List<ClipEntry>>,
        markers: Map<String, List<DeletedClipEntry>>,
        now: Long
    ): List<ClipDatabase> = channels.map { state ->
        val entries = routed[state.key] ?: emptyList()
        SyncConflictResolver.normalized(
            ClipDatabase(
                Version = maxOf(1, state.database.Version),
                UpdatedUnixMs = now,
                Entries = entries,
                DeletedEntries = dropMarkersForEntries(markers[state.key] ?: emptyList(), entries)
            )
        )
    }

    /**
     * The phase-one entry assignment: what each channel keeps plus what it is
     * about to lose, carried in the copy the channel was fetched with so the
     * target's newer copy wins view assembly for the transient window in which
     * both channels hold the id.
     */
    private fun withDepartures(
        routed: Map<String, List<ClipEntry>>,
        departures: Map<String, List<ClipEntry>>,
        fetched: Map<String, Map<String, ClipEntry>>
    ): Map<String, List<ClipEntry>> {
        if (departures.isEmpty()) return routed
        val combined = HashMap<String, List<ClipEntry>>(routed)
        for ((key, leaving) in departures) {
            if (leaving.isEmpty()) continue
            val staying = (combined[key] ?: emptyList()).toMutableList()
            for (entry in leaving) {
                staying.add(fetched[key]?.get(comparableClipId(entry.Id)) ?: entry)
            }
            combined[key] = staying
        }
        return combined
    }

    /**
     * Removes markers naming an entry being written into the same channel.
     * Without this a relocation marker left behind by an earlier move would
     * delete the entry again when a rule change moves it back.
     */
    private fun dropMarkersForEntries(
        markers: List<DeletedClipEntry>,
        entries: List<ClipEntry>
    ): List<DeletedClipEntry> {
        if (markers.isEmpty() || entries.isEmpty()) return markers
        val resident = entries.mapTo(HashSet()) { comparableClipId(it.Id) }
        return markers.filterNot { resident.contains(comparableClipId(it.Id)) }
    }

    /**
     * Uploads one channel with the conditional header its state calls for, and
     * on a conflict re-reads that channel, merges the local build into the
     * server copy and retries.
     */
    private fun putChannel(
        transport: MobileChannelTransport,
        state: MobileChannelState,
        database: ClipDatabase
    ): MobileChannelState {
        var current = state
        var payload = database
        var last: Throwable? = null
        for (attempt in 0..uploadRetries) {
            try {
                val written = transport.write(current.key, payload, current.revision, current.exists)
                return current.copy(
                    revision = written.revision,
                    plainHash = SyncRuleEngine.durablePlainHash(payload),
                    database = payload,
                    exists = true,
                    salt = written.salt ?: current.salt
                )
            } catch (error: Throwable) {
                if (error !is ServerConflictException && error !is ServerDatabaseNotFoundException) throw error
                last = error
                Thread.sleep(30L + attempt * 40L)
                val fresh = transport.read(current.key)
                current = if (fresh == null) {
                    current.copy(revision = "", exists = false)
                } else {
                    payload = SyncConflictResolver.merge(
                        target = SyncConflictResolver.normalized(fresh.database),
                        source = payload
                    )
                    current.copy(revision = fresh.revision, exists = true, salt = fresh.salt ?: current.salt)
                }
            }
        }
        throw IllegalStateException(
            "The ${channelLabel(current.key)} changed repeatedly; the change was not committed.",
            last
        )
    }

    /** The text-hash half of the deletion rule, the only one crossing channels. */
    private fun textMarkerSuppresses(marker: DeletedClipEntry, entry: ClipEntry): Boolean {
        if (marker.TextHash.isEmpty()) return false
        if (!marker.TextHash.equals(SyncConflictResolver.textHash(entry.Text), ignoreCase = true)) return false
        val changed = maxOf(entry.CreatedUnixMs, entry.LastUsedUnixMs)
        return marker.DeletedUnixMs <= 0 || changed <= marker.DeletedUnixMs
    }

    private fun joinFailures(writeThrough: Throwable?, cause: Throwable): Throwable {
        if (writeThrough != null && writeThrough !== cause) cause.addSuppressed(writeThrough)
        return cause
    }

    fun channelLabel(channelKey: String): String =
        if (channelKey.isEmpty()) "main history" else "\"$channelKey\" channel"
}

@Serializable
internal data class ChannelSyncRecord(
    val Key: String = "",
    val Revision: String = "",
    val PlainHash: String = "",
    val CacheHash: String = "",
    val Exists: Boolean = false
)

@Serializable
internal data class ChannelSyncState(
    val RulesRevision: String = "",
    val Channels: List<ChannelSyncRecord> = emptyList()
)

private val channelStateJson = Json {
    ignoreUnknownKeys = true
    encodeDefaults = true
    coerceInputValues = true
}

class MobileHistoryRepository(context: Context) {
    private val appContext = context.applicationContext
    private val localStore = LocalHistoryStore(context)
    private val channelStores = HashMap<String, LocalHistoryStore>()
    private val settings by lazy { AndroidSettings(appContext) }

    fun loadLocal(password: String): ClipDatabase {
        val existing = localStore.load(password)
        if (existing != null) return existing
        val empty = ClipDatabase()
        localStore.save(empty, password)
        return empty
    }

    fun loadLocalOrNull(password: String): ClipDatabase? = localStore.load(password)

    /**
     * The cached view: the core history file merged with every subscribed
     * channel's cache file, so an offline start shows the same entries a
     * successful poll would.
     */
    fun loadCachedView(password: String, deviceName: String): ClipDatabase? {
        val core = localStore.load(password) ?: return null
        val document = cachedSyncRules()
        if (document == null || !document.Enabled) return core
        val states = mutableListOf(
            MobileChannelState(key = "", database = SyncConflictResolver.normalized(core), exists = true)
        )
        for (key in SyncRuleEngine.subscribedKeys(document, deviceName)) {
            val cached = runCatching { channelStore(key).load(password) }.getOrNull() ?: continue
            states.add(
                MobileChannelState(key = key, database = SyncConflictResolver.normalized(cached), exists = true)
            )
        }
        if (states.size == 1) return core
        return MobileChannelEngine.buildView(states).view
    }

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

    // -- Sync rules state -------------------------------------------------

    fun cachedSyncRules(): SyncRulesDocument? {
        val payload = runCatching { settings.syncRulesDocument }.getOrElse { "" }
        if (payload.isBlank()) return null
        return SyncRuleEngine.parse(payload)
    }

    fun syncRulesSnapshot(deviceName: String): MobileSyncRulesSnapshot {
        val document = cachedSyncRules()
        return MobileSyncRulesSnapshot(
            document = document,
            readOnly = SyncRuleEngine.isReadOnly(document),
            subscribesToAll = SyncRuleEngine.subscribesToAllChannels(document, deviceName),
            subscribedKeys = SyncRuleEngine.subscribedKeys(document, deviceName),
            registered = SyncRuleEngine.isRegistered(document, deviceName),
            pendingChannelKeys = loadPendingWrites().Channels.map { it.ChannelKey }.filter { it.isNotEmpty() }
        )
    }

    private fun storeSyncRules(document: SyncRulesDocument?) {
        runCatching {
            settings.syncRulesDocument = document?.let { SyncRuleEngine.serialize(it) } ?: ""
        }
    }

    private fun loadPendingWrites(): PendingChannelWrites {
        val payload = runCatching { settings.pendingChannelWrites }.getOrElse { "" }
        if (payload.isBlank()) return PendingChannelWrites()
        return SyncRuleEngine.parsePendingWrites(payload)
    }

    private fun storePendingWrites(pending: PendingChannelWrites) {
        runCatching {
            settings.pendingChannelWrites =
                if (pending.Channels.isEmpty()) "" else SyncRuleEngine.serializePendingWrites(pending)
        }
    }

    private fun loadChannelSyncState(): ChannelSyncState {
        val payload = runCatching { settings.channelSyncState }.getOrElse { "" }
        if (payload.isBlank()) return ChannelSyncState()
        return runCatching { channelStateJson.decodeFromString(ChannelSyncState.serializer(), payload) }
            .getOrElse { ChannelSyncState() }
    }

    private fun storeChannelSyncState(state: ChannelSyncState) {
        runCatching {
            settings.channelSyncState = channelStateJson.encodeToString(ChannelSyncState.serializer(), state)
        }
    }

    private fun channelStore(key: String): LocalHistoryStore = channelStores.getOrPut(key) {
        if (key.isEmpty()) localStore else LocalHistoryStore(appContext, LocalHistoryStore.channelFileName(key))
    }

    // -- Polling ----------------------------------------------------------

    /**
     * Whether the rules bucket and every subscribed channel still hold the
     * revision this device last saw, so a poll tick can skip every download
     * (spec section 5, download steps 1 and 2).
     */
    fun serverUnchanged(
        serverUrl: String,
        token: String,
        password: String,
        serverCaCertPem: String,
        serverCaHost: String,
        deviceName: String,
        expectedRevision: String
    ): Boolean {
        val client = ServerStorageClient(serverUrl, token, password, serverCaCertPem, serverCaHost)
        if (client.metadata() != expectedRevision) return false

        val persisted = loadChannelSyncState()
        val rulesClient = client.forSyncRules()
        if (rulesClient != null && rulesClient.metadata() != persisted.RulesRevision) return false

        val document = cachedSyncRules() ?: return true
        if (!document.Enabled) return true
        if (loadPendingWrites().Channels.isNotEmpty()) return false
        for (key in SyncRuleEngine.subscribedKeys(document, deviceName)) {
            val channelClient = client.forChannel(key) ?: continue
            val known = persisted.Channels.firstOrNull { it.Key == key }?.Revision ?: ""
            if (channelClient.metadata() != known) return false
        }
        return true
    }

    // -- Mutation and synchronization -------------------------------------

    fun persistMutation(
        serverUrl: String,
        token: String,
        password: String,
        serverCaCertPem: String,
        serverCaHost: String,
        current: ClipDatabase,
        expectedRevision: String,
        backupOptions: CloudBackupOptions = CloudBackupOptions(false, ""),
        deviceName: String = ""
    ): MobileSyncResult {
        val document = cachedSyncRules()
        if (document == null || !document.Enabled) {
            return persistSingleBucketMutation(
                serverUrl, token, password, serverCaCertPem, serverCaHost,
                current, expectedRevision, backupOptions, deviceName
            )
        }

        val persisted = loadChannelSyncState()
        val base = fastPathBase(document, deviceName, password, persisted, expectedRevision)
            ?: return synchronize(
                serverUrl, token, password, serverCaCertPem, serverCaHost,
                current, backupOptions, localAlreadySaved = false, deviceName = deviceName
            )

        val client = ServerStorageClient(serverUrl, token, password, serverCaCertPem, serverCaHost)
        val transport = ServerChannelTransport(client, password)
        transport.seedCoreSalt(localStore.salt)
        return commitChannels(
            transport = transport,
            document = document,
            channels = base.channels,
            residence = base.residence,
            previousMarkers = base.view.DeletedEntries.associateBy { comparableClipId(it.Id) },
            mutated = SyncConflictResolver.normalized(current),
            deviceName = deviceName,
            password = password,
            backupOptions = backupOptions,
            persisted = persisted,
            rulesRevision = persisted.RulesRevision
        )
    }

    fun synchronize(
        serverUrl: String,
        token: String,
        password: String,
        serverCaCertPem: String,
        serverCaHost: String,
        current: ClipDatabase,
        backupOptions: CloudBackupOptions = CloudBackupOptions(false, ""),
        localAlreadySaved: Boolean = false,
        deviceName: String = ""
    ): MobileSyncResult {
        val client = ServerStorageClient(serverUrl, token, password, serverCaCertPem, serverCaHost)
        val persisted = loadChannelSyncState()
        val transport = ServerChannelTransport(client, password)
        // The cached core container supplies the salt every other bucket copies,
        // so the rules bucket can be restored before core is downloaded.
        transport.seedCoreSalt(runCatching { localStore.peekSalt() }.getOrNull())

        val rules = readRules(client, password, persisted, transport.coreSalt)
        val effective = rules.document
        if (effective == null || !effective.Enabled) {
            storeSyncRules(effective)
            storeChannelSyncState(ChannelSyncState(RulesRevision = rules.revision))
            return synchronizeSingleBucket(client, password, current, backupOptions, localAlreadySaved)
        }
        var document: SyncRulesDocument = effective
        var rulesRevision = rules.revision

        // Registry behavior: an updated client whose device name is missing
        // from Devices adds itself with Channels ["*"] on its next sync. It is
        // skipped without a known revision, so the write never clobbers a
        // document this device has not seen.
        if (deviceName.isNotBlank() &&
            rulesRevision.isNotBlank() &&
            !SyncRuleEngine.isReadOnly(document) &&
            !SyncRuleEngine.isRegistered(document, deviceName)
        ) {
            val registered = SyncRuleEngine.withDeviceSubscription(
                document, deviceName, null, TimeUtil.nowUnixMs()
            )
            val revision = runCatching {
                uploadRules(client, registered, password, rulesRevision, transport.coreSalt)
            }.getOrNull()
            if (revision != null) {
                document = registered
                rulesRevision = revision
            }
        }

        retryPendingWrites(transport)

        // Core is read first so every other bucket can copy its salt.
        val states = mutableListOf(readChannelState(transport, "", password, persisted))
        for (key in SyncRuleEngine.subscribedKeys(document, deviceName)) {
            if (client.forChannel(key) == null) continue
            states.add(readChannelState(transport, key, password, persisted))
        }
        val assembly = MobileChannelEngine.buildView(states)

        val cached = if (localAlreadySaved) current else loadCachedView(password, deviceName)
        val local = if (localAlreadySaved) {
            current
        } else {
            cached?.let { SyncConflictResolver.merge(target = current, source = it) } ?: current
        }
        val mutated = SyncConflictResolver.merge(target = local, source = assembly.view)

        return commitChannels(
            transport = transport,
            document = document,
            channels = states,
            residence = assembly.residence,
            previousMarkers = assembly.view.DeletedEntries.associateBy { comparableClipId(it.Id) },
            mutated = mutated,
            deviceName = deviceName,
            password = password,
            backupOptions = backupOptions,
            persisted = persisted,
            rulesRevision = rulesRevision
        )
    }

    /**
     * Replaces this device's subscription in the shared rules document. A
     * future-version document is display only and is never rewritten.
     */
    fun saveDeviceSubscription(
        serverUrl: String,
        token: String,
        password: String,
        serverCaCertPem: String,
        serverCaHost: String,
        deviceName: String,
        channels: List<String>?
    ): SyncRulesDocument {
        require(deviceName.isNotBlank()) { "Set a device name before changing sync rules." }
        val client = ServerStorageClient(serverUrl, token, password, serverCaCertPem, serverCaHost)
        client.forSyncRules() ?: throw IllegalStateException(
            "Sync rules need a Clipman Server token and a history password."
        )
        val coreSalt = runCatching { localStore.peekSalt() }.getOrNull()
        val persisted = loadChannelSyncState()
        val current = readRules(client, password, persisted, coreSalt)
        val document = current.document
            ?: throw IllegalStateException("This Clipman Server has no sync rules document yet.")
        if (SyncRuleEngine.isReadOnly(document)) {
            throw IllegalStateException(
                "These sync rules were written by a newer version of Clipman and cannot be changed here."
            )
        }
        val updated = SyncRuleEngine.withDeviceSubscription(
            document, deviceName, channels, TimeUtil.nowUnixMs()
        )
        val revision = uploadRules(client, updated, password, current.revision, coreSalt)
        storeSyncRules(updated)
        storeChannelSyncState(persisted.copy(RulesRevision = revision))
        return updated
    }

    // -- Channel plumbing -------------------------------------------------

    private class FastPathBase(
        val channels: List<MobileChannelState>,
        val view: ClipDatabase,
        val residence: Map<String, String>
    )

    /**
     * The last committed channel state, rebuilt from the local caches without
     * touching the network. It is only usable while every cache still mirrors
     * exactly what the server was last known to hold; otherwise the caller
     * falls back to a full synchronize.
     */
    private fun fastPathBase(
        document: SyncRulesDocument,
        deviceName: String,
        password: String,
        persisted: ChannelSyncState,
        expectedRevision: String
    ): FastPathBase? {
        if (expectedRevision.isBlank()) return null
        val keys = listOf("") + SyncRuleEngine.subscribedKeys(document, deviceName)
        val states = mutableListOf<MobileChannelState>()
        for (key in keys) {
            val record = persisted.Channels.firstOrNull { it.Key == key } ?: return null
            if (key.isEmpty() && record.Revision != expectedRevision) return null
            if (!record.Exists || record.Revision.isBlank()) return null
            if (record.CacheHash.isBlank() || record.CacheHash != record.PlainHash) return null
            val cached = runCatching { channelStore(key).load(password) }.getOrNull() ?: return null
            val normalized = SyncConflictResolver.normalized(cached)
            if (SyncRuleEngine.durablePlainHash(normalized) != record.PlainHash) return null
            states.add(
                MobileChannelState(
                    key = key,
                    revision = record.Revision,
                    plainHash = record.PlainHash,
                    database = normalized,
                    exists = true,
                    salt = channelStore(key).salt
                )
            )
        }
        if (states.isEmpty()) return null
        val assembly = MobileChannelEngine.buildView(states)
        return FastPathBase(states, assembly.view, assembly.residence)
    }

    private fun readChannelState(
        transport: ServerChannelTransport,
        key: String,
        password: String,
        persisted: ChannelSyncState
    ): MobileChannelState {
        val record = persisted.Channels.firstOrNull { it.Key == key }
        if (record != null && record.Exists && record.Revision.isNotBlank()) {
            val revision = transport.revision(key)
            if (revision == record.Revision) {
                val cached = runCatching { channelStore(key).load(password) }.getOrNull()
                if (cached != null) {
                    val normalized = SyncConflictResolver.normalized(cached)
                    if (SyncRuleEngine.durablePlainHash(normalized) == record.PlainHash) {
                        return MobileChannelState(
                            key = key,
                            revision = revision,
                            plainHash = record.PlainHash,
                            database = normalized,
                            exists = true,
                            salt = channelStore(key).salt
                        )
                    }
                }
            }
        }
        val fetch = transport.read(key)
        if (fetch == null) {
            val empty = SyncConflictResolver.normalized(ClipDatabase())
            return MobileChannelState(
                key = key,
                revision = "",
                plainHash = SyncRuleEngine.durablePlainHash(empty),
                database = empty,
                exists = false,
                salt = null
            )
        }
        val normalized = SyncConflictResolver.normalized(fetch.database)
        return MobileChannelState(
            key = key,
            revision = fetch.revision,
            plainHash = SyncRuleEngine.durablePlainHash(normalized),
            database = normalized,
            exists = true,
            salt = fetch.salt
        )
    }

    private class RulesRead(val document: SyncRulesDocument?, val revision: String)

    private fun readRules(
        client: ServerStorageClient,
        password: String,
        persisted: ChannelSyncState,
        coreSalt: ByteArray?
    ): RulesRead {
        val rulesClient = client.forSyncRules() ?: return RulesRead(null, "")
        val cached = cachedSyncRules()

        // Download step 1: HEAD the rules bucket and GET only when it changed.
        val revision = rulesClient.metadata()
        if (revision.isBlank()) {
            // A cached future-version document is display only: it must never be
            // re-uploaded, so it does not arm this 404 fallback, and a genuine
            // rules loss leaves such a client with rules disabled.
            if (cached == null || SyncRuleEngine.isReadOnly(cached)) return RulesRead(cached, "")
            return RulesRead(cached, restoreRulesFromCache(client, cached, password, coreSalt))
        }
        if (revision == persisted.RulesRevision && cached != null) return RulesRead(cached, revision)

        val download = try {
            rulesClient.download()
        } catch (_: ServerDatabaseNotFoundException) {
            if (cached == null || SyncRuleEngine.isReadOnly(cached)) return RulesRead(cached, "")
            return RulesRead(cached, restoreRulesFromCache(client, cached, password, coreSalt))
        }
        val payload = runCatching { ClipDatabaseFile.loadRawText(download.data, password) }.getOrNull()
            ?: return RulesRead(cached, "")
        val remote = SyncRuleEngine.parse(payload) ?: return RulesRead(cached, "")
        val merged = SyncRuleEngine.mergeDocuments(cached, remote)
        // When the cache wins the merge, the effective document is not the one
        // the server holds, so no revision is reported: an If-Match against it
        // would claim an edit was based on a document the server never saw.
        return if (merged !== remote) RulesRead(merged, "") else RulesRead(merged, download.revision)
    }

    private fun restoreRulesFromCache(
        client: ServerStorageClient,
        document: SyncRulesDocument,
        password: String,
        coreSalt: ByteArray?
    ): String = runCatching {
        // Best effort re-creation of a rules bucket that disappeared. It is
        // retried on the next read when it fails, and a document another device
        // wrote in the meantime wins the next last-writer-wins merge.
        uploadRules(client, document, password, "", coreSalt)
    }.getOrElse { "" }

    private fun uploadRules(
        client: ServerStorageClient,
        document: SyncRulesDocument,
        password: String,
        expectedRevision: String,
        coreSalt: ByteArray?
    ): String {
        val rulesClient = client.forSyncRules()
            ?: throw IllegalStateException("Sync rules need a Clipman Server token and a history password.")
        val encoded = ClipDatabaseFile.saveRawText(
            SyncRuleEngine.serialize(document),
            password,
            preferredSalt = coreSalt
        )
        return rulesClient.upload(encoded, expectedRevision).revision
    }

    private fun retryPendingWrites(transport: ServerChannelTransport) {
        val pending = loadPendingWrites()
        if (pending.Channels.isEmpty()) return
        val remaining = mutableListOf<PendingChannelWrite>()
        for (write in pending.Channels) {
            val key = SyncRuleEngine.channelKey(write.ChannelKey)
            if (key.isEmpty() || write.Entries.isEmpty()) continue
            try {
                MobileChannelEngine.deliver(transport, key, write.Entries)
            } catch (_: Throwable) {
                remaining.add(write)
            }
        }
        storePendingWrites(PendingChannelWrites(remaining))
    }

    private fun commitChannels(
        transport: ServerChannelTransport,
        document: SyncRulesDocument,
        channels: List<MobileChannelState>,
        residence: Map<String, String>,
        previousMarkers: Map<String, DeletedClipEntry>,
        mutated: ClipDatabase,
        deviceName: String,
        password: String,
        backupOptions: CloudBackupOptions,
        persisted: ChannelSyncState,
        rulesRevision: String
    ): MobileSyncResult {
        val now = TimeUtil.nowUnixMs()
        val cacheHashes = HashMap<String, String>()
        persisted.Channels.forEach { cacheHashes[it.Key] = it.CacheHash }

        fun cacheChannel(key: String, database: ClipDatabase) {
            val hash = SyncRuleEngine.durablePlainHash(database)
            if (cacheHashes[key] == hash) return
            cacheHashes[key] = writeChannelCache(key, database, password, transport.coreSalt) ?: ""
        }

        // The content this save intends to leave behind is written to the local
        // caches before any upload starts, so an offline save is never lost.
        val planned = MobileChannelEngine.planChannelDatabases(
            document, channels, residence, previousMarkers, mutated, deviceName, now
        )
        channels.forEachIndexed { index, state -> cacheChannel(state.key, planned[index]) }

        val commit = MobileChannelEngine.commit(
            transport = transport,
            document = document,
            base = channels,
            residence = residence,
            previousMarkers = previousMarkers,
            mutated = mutated,
            deviceName = deviceName,
            now = now
        )

        for (state in commit.channels) cacheChannel(state.key, state.database)

        if (commit.pending.isNotEmpty()) {
            val existing = loadPendingWrites().Channels.filter { write ->
                !commit.pending.containsKey(SyncRuleEngine.channelKey(write.ChannelKey))
            }
            storePendingWrites(
                PendingChannelWrites(
                    existing + commit.pending.map { (key, entries) -> PendingChannelWrite(key, entries) }
                )
            )
        }

        storeSyncRules(document)
        storeChannelSyncState(
            ChannelSyncState(
                RulesRevision = rulesRevision.ifBlank { persisted.RulesRevision },
                Channels = commit.channels.map { state ->
                    ChannelSyncRecord(
                        Key = state.key,
                        Revision = state.revision,
                        PlainHash = state.plainHash,
                        CacheHash = cacheHashes[state.key] ?: "",
                        Exists = state.exists
                    )
                }
            )
        )

        if (!commit.committed) {
            throw MobileMutationException(
                commit.failure ?: IllegalStateException("The change could not be synced."),
                localSaved = true
            )
        }

        val backupError = if (backupOptions.enabled) {
            runCatching {
                CloudHistoryBackup.write(
                    appContext,
                    ClipDatabaseFile.save(commit.view, password, preferredSalt = transport.coreSalt),
                    backupOptions
                )
            }.getOrElse { it.message ?: it::class.java.simpleName }
        } else {
            null
        }

        val notices = mutableListOf<String>()
        if (commit.delivered.isNotEmpty()) {
            val names = commit.delivered.joinToString(", ") { SyncRuleEngine.channelDisplayName(document, it) }
            notices.add("Added to $names for your other devices.")
        }
        if (commit.pending.isNotEmpty()) {
            val names = commit.pending.keys.joinToString(", ") { SyncRuleEngine.channelDisplayName(document, it) }
            notices.add("Entries for $names will be delivered when Clipman Server is reachable.")
        }
        return MobileSyncResult(
            database = commit.view,
            revision = commit.channels.firstOrNull()?.revision ?: "",
            uploaded = commit.uploads > 0,
            backupError = backupError,
            writeThroughMessage = notices.joinToString(" ").ifBlank { null }
        )
    }

    private fun writeChannelCache(
        key: String,
        database: ClipDatabase,
        password: String,
        coreSalt: ByteArray?
    ): String? = runCatching {
        val store = channelStore(key)
        store.adoptSalt(coreSalt)
        store.save(database, password)
        SyncRuleEngine.durablePlainHash(database)
    }.getOrNull()

    // -- Single bucket paths ----------------------------------------------

    private fun persistSingleBucketMutation(
        serverUrl: String,
        token: String,
        password: String,
        serverCaCertPem: String,
        serverCaHost: String,
        current: ClipDatabase,
        expectedRevision: String,
        backupOptions: CloudBackupOptions,
        deviceName: String
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
                        localAlreadySaved = true,
                        deviceName = deviceName
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

    private fun synchronizeSingleBucket(
        client: ServerStorageClient,
        password: String,
        current: ClipDatabase,
        backupOptions: CloudBackupOptions,
        localAlreadySaved: Boolean
    ): MobileSyncResult {
        val cached = if (localAlreadySaved) current else localStore.load(password)
        val local = if (localAlreadySaved) {
            current
        } else {
            cached?.let { SyncConflictResolver.merge(target = current, source = it) } ?: current
        }
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
