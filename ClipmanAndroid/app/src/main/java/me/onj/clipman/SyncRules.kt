package me.onj.clipman

import java.security.MessageDigest
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * The sync rules document of sync-rules-spec.md section 4: the channels, their
 * routes, and the per-device subscriptions. It lives in its own bucket, never
 * inside the history database, and its JSON field names are the PascalCase
 * names every Clipman client shares.
 */
@Serializable
data class SyncRulesDocument(
    val Clipman: String = SyncRuleEngine.documentKind,
    val Version: Int = SyncRuleEngine.currentVersion,
    val Enabled: Boolean = false,
    val UpdatedUnixMs: Long = 0,
    val UpdatedBy: String = "",
    val Channels: List<SyncChannel> = emptyList(),
    val Devices: List<SyncDevice> = emptyList()
)

@Serializable
data class SyncChannel(
    val Name: String = "",
    val Route: SyncRoute = SyncRoute()
)

/**
 * The conditions that route an entry into one channel. Conditions are ANDed
 * together and a valid route sets at least one of them.
 */
@Serializable
data class SyncRoute(
    val Groups: List<String> = emptyList(),
    val SourceDevices: List<String> = emptyList(),
    val Kind: String = ""
)

@Serializable
data class SyncDevice(
    val Name: String = "",
    val Channels: List<String> = emptyList()
)

/**
 * Entries captured on this device that route to a channel it does not
 * subscribe to and whose write-through failed (spec section 6). They are kept
 * here and retried after the next successful poll; they never appear in the
 * local view.
 */
@Serializable
data class PendingChannelWrite(
    val ChannelKey: String = "",
    val Entries: List<ClipEntry> = emptyList()
)

@Serializable
data class PendingChannelWrites(
    val Channels: List<PendingChannelWrite> = emptyList()
)

/**
 * The document model and routing engine of sync-rules-spec.md sections 3 and
 * 4. Every derivation here must produce the same result on every platform, so
 * all comparisons use lowerInvariant(trim(x)) and the channel key grammar is
 * ASCII only.
 */
object SyncRuleEngine {
    const val documentKind = "sync-rules"
    const val currentVersion = 1
    const val richTextImagesKind = "RichTextImages"

    private const val dataImagePrefix = "data:image/"

    /** [a-z0-9]([a-z0-9 _-]{0,30}[a-z0-9])? - ASCII only, 1 to 32 characters. */
    private val channelKeyPattern = Regex("^[a-z0-9]([a-z0-9 _-]{0,30}[a-z0-9])?$")

    private val reservedChannelKeys = setOf("core", "all", "pinned", "sync-rules")

    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
        coerceInputValues = true
    }

    /** The lowerInvariant(trim(x)) comparison form used throughout section 3. */
    fun normalizedName(value: String): String = value.trim().lowercase()

    /**
     * The channel key for a display name, or "" when the name is not a legal
     * channel name. The grammar is ASCII only, so a name that folds to
     * anything outside it yields no key and never routes.
     */
    fun channelKey(name: String): String {
        val key = normalizedName(name)
        return if (channelKeyPattern.matches(key)) key else ""
    }

    /**
     * The channel key as it appears in file names, where spaces become dashes
     * (spec section 2). Two keys that fold to the same storage name would
     * share one file, so [validate] rejects such a document.
     */
    fun channelStorageName(key: String): String = key.replace(' ', '-')

    /**
     * A document written by a newer format version is applied but never
     * rewritten by this client (spec section 4, Version).
     */
    fun isReadOnly(document: SyncRulesDocument?): Boolean =
        document != null && document.Version > currentVersion

    /** Returns null when the document is valid, or the reason it is not. */
    fun validate(document: SyncRulesDocument?): String? {
        if (document == null) return "The sync rules document is missing."
        if (document.Clipman != documentKind) return "The sync rules document has an unrecognized format."

        val knownKeys = mutableSetOf<String>()
        val storageNames = mutableSetOf<String>()
        for (channel in document.Channels) {
            val key = channelKey(channel.Name)
            if (key.isEmpty()) return "Channel name \"${channel.Name}\" is not valid."
            if (reservedChannelKeys.contains(key)) return "Channel name \"${channel.Name}\" is reserved."
            if (!knownKeys.add(key)) return "Channel name \"${channel.Name}\" is not unique."
            if (!storageNames.add(channelStorageName(key))) {
                return "Channel name \"${channel.Name}\" would share a storage file with another channel."
            }

            val route = channel.Route
            if (route.Groups.isEmpty() && route.SourceDevices.isEmpty() && route.Kind.isEmpty()) {
                return "Channel \"${channel.Name}\" has no routing condition."
            }
            if (route.Kind.isNotEmpty() && route.Kind != richTextImagesKind) {
                return "Channel \"${channel.Name}\" has an unrecognized route kind."
            }
        }

        for (device in document.Devices) {
            if (device.Channels.any { it.trim() == "*" } && device.Channels.size != 1) {
                return "Device \"${device.Name}\" mixes \"*\" with named channels."
            }
            for (channelReference in device.Channels) {
                if (channelReference.trim() == "*") continue
                if (!knownKeys.contains(normalizedName(channelReference))) {
                    return "Device \"${device.Name}\" references unknown channel \"$channelReference\"."
                }
            }
        }

        return null
    }

    /**
     * Whether a document read from storage may be applied. A future-version
     * document is accepted leniently - a client must never fail entirely on a
     * document it only partly understands - while a current-version document
     * must still pass strict validation, because editors validate before
     * writing. Channels whose name yields no key stay in the document but
     * never route.
     */
    fun isUsable(document: SyncRulesDocument?): Boolean {
        if (document == null) return false
        if (document.Clipman != documentKind) return false
        if (isReadOnly(document)) return true
        return validate(document) == null
    }

    /** Decodes a rules document, returning null when it cannot be applied. */
    fun parse(payload: String): SyncRulesDocument? {
        val document = runCatching { json.decodeFromString(SyncRulesDocument.serializer(), payload) }.getOrNull()
        return if (isUsable(document)) document else null
    }

    fun serialize(document: SyncRulesDocument): String =
        json.encodeToString(SyncRulesDocument.serializer(), document)

    fun parsePendingWrites(payload: String): PendingChannelWrites =
        runCatching { json.decodeFromString(PendingChannelWrites.serializer(), payload) }
            .getOrElse { PendingChannelWrites() }

    fun serializePendingWrites(pending: PendingChannelWrites): String =
        json.encodeToString(PendingChannelWrites.serializer(), pending)

    /**
     * The dirty-detection hash of spec section 5, upload step 4: the SHA-256
     * of the deterministic plaintext JSON with the database-level
     * UpdatedUnixMs zeroed. Zeroing it makes the hash durable across poll
     * cycles, because normalization restamps that field on every pass.
     */
    fun durablePlainHash(database: ClipDatabase): String {
        val payload = json.encodeToString(ClipDatabase.serializer(), database.copy(UpdatedUnixMs = 0))
        val digest = MessageDigest.getInstance("SHA-256").digest(payload.toByteArray(Charsets.UTF_8))
        return digest.joinToString("") { "%02x".format(it) }
    }

    /**
     * The key of the first channel, in document order, whose route matches the
     * entry, or "" when the document is absent, disabled, or nothing matches -
     * meaning the entry lives in core.
     */
    fun routeEntry(document: SyncRulesDocument?, entry: ClipEntry?): String {
        if (document == null || !document.Enabled || entry == null) return ""
        for (channel in document.Channels) {
            val key = channelKey(channel.Name)
            if (key.isEmpty()) continue
            if (routeMatches(channel.Route, entry)) return key
        }
        return ""
    }

    /** Every routable channel key in the document, in document order. */
    fun allChannelKeys(document: SyncRulesDocument?): List<String> {
        if (document == null) return emptyList()
        val keys = mutableListOf<String>()
        for (channel in document.Channels) {
            val key = channelKey(channel.Name)
            if (key.isNotEmpty() && !keys.contains(key)) keys.add(key)
        }
        return keys
    }

    /**
     * The channels the named device downloads besides core, or null when the
     * device is not listed, which per spec section 4 means "subscribe to
     * everything".
     */
    fun subscribedChannels(document: SyncRulesDocument?, deviceName: String): List<String>? {
        if (document == null || !document.Enabled) return null

        val wanted = normalizedName(deviceName)
        val device = document.Devices.firstOrNull { normalizedName(it.Name) == wanted } ?: return null

        val allKeys = allChannelKeys(document)
        if (device.Channels.size == 1 && device.Channels[0].trim() == "*") return allKeys

        val subscribed = mutableListOf<String>()
        for (channelReference in device.Channels) {
            val key = normalizedName(channelReference)
            if (allKeys.contains(key) && !subscribed.contains(key)) subscribed.add(key)
        }
        return subscribed
    }

    /** Whether the named device subscribes to every channel, now and later. */
    fun subscribesToAllChannels(document: SyncRulesDocument?, deviceName: String): Boolean {
        if (document == null) return true
        val wanted = normalizedName(deviceName)
        val device = document.Devices.firstOrNull { normalizedName(it.Name) == wanted } ?: return true
        return device.Channels.size == 1 && device.Channels[0].trim() == "*"
    }

    fun isRegistered(document: SyncRulesDocument?, deviceName: String): Boolean {
        if (document == null) return false
        val wanted = normalizedName(deviceName)
        return document.Devices.any { normalizedName(it.Name) == wanted }
    }

    /**
     * The channels the named device downloads, in document order and without
     * core, which every device downloads implicitly.
     */
    fun subscribedKeys(document: SyncRulesDocument?, deviceName: String): List<String> {
        if (document == null || !document.Enabled) return emptyList()
        val subscribed = subscribedChannels(document, deviceName)
        if (subscribed == null) return allChannelKeys(document)
        return allChannelKeys(document).filter { subscribed.contains(it) }
    }

    /** The display name of a channel key, falling back to the key itself. */
    fun channelDisplayName(document: SyncRulesDocument?, key: String): String {
        if (key.isEmpty()) return "main history"
        val match = document?.Channels?.firstOrNull { channelKey(it.Name) == key }
        return match?.Name?.trim()?.takeIf { it.isNotEmpty() } ?: key
    }

    /** A one-line description of a route for the rules screen. */
    fun routeDescription(route: SyncRoute): String {
        val conditions = mutableListOf<String>()
        if (route.Groups.isNotEmpty()) conditions.add("group is ${route.Groups.joinToString(" or ")}")
        if (route.SourceDevices.isNotEmpty()) conditions.add("device is ${route.SourceDevices.joinToString(" or ")}")
        when {
            route.Kind == richTextImagesKind -> conditions.add("the entry contains a Rich Text image")
            route.Kind.isNotEmpty() ->
                conditions.add("a condition this version of Clipman does not understand, so nothing matches")
        }
        if (conditions.isEmpty()) return "No routing condition."
        return conditions.joinToString(" and ") + "."
    }

    /**
     * Whole-document last-writer-wins on UpdatedUnixMs, breaking ties toward
     * the greater UpdatedBy string by ordinal comparison. A null document
     * loses to a non-null one.
     */
    fun mergeDocuments(local: SyncRulesDocument?, remote: SyncRulesDocument?): SyncRulesDocument? {
        if (local == null) return remote
        if (remote == null) return local
        if (remote.UpdatedUnixMs > local.UpdatedUnixMs) return remote
        if (remote.UpdatedUnixMs < local.UpdatedUnixMs) return local
        return if (remote.UpdatedBy > local.UpdatedBy) remote else local
    }

    /**
     * The document with the named device's subscription replaced. Passing null
     * for channels registers the device as subscribing to every channel.
     */
    fun withDeviceSubscription(
        document: SyncRulesDocument,
        deviceName: String,
        channels: List<String>?,
        updatedUnixMs: Long
    ): SyncRulesDocument {
        val wanted = normalizedName(deviceName)
        val replacement = SyncDevice(
            Name = deviceName.trim(),
            Channels = channels?.map { normalizedName(it) }?.filter { it.isNotEmpty() } ?: listOf("*")
        )
        val devices = document.Devices.toMutableList()
        val index = devices.indexOfFirst { normalizedName(it.Name) == wanted }
        if (index >= 0) devices[index] = replacement else devices.add(replacement)
        return document.copy(
            Devices = devices,
            UpdatedUnixMs = updatedUnixMs,
            UpdatedBy = deviceName.trim()
        )
    }

    private fun routeMatches(route: SyncRoute, entry: ClipEntry): Boolean {
        var hasCondition = false

        if (route.Groups.isNotEmpty()) {
            hasCondition = true
            if (!containsNormalized(route.Groups, entry.Group)) return false
        }
        if (route.SourceDevices.isNotEmpty()) {
            hasCondition = true
            if (!containsNormalized(route.SourceDevices, entry.SourceMachine)) return false
        }
        if (route.Kind.isNotEmpty()) {
            hasCondition = true
            if (!matchesKind(route.Kind, entry)) return false
        }

        return hasCondition
    }

    private fun matchesKind(kind: String, entry: ClipEntry): Boolean {
        if (kind != richTextImagesKind) return false
        val html = entry.RichText?.HtmlFragment ?: return false
        return html.contains(dataImagePrefix)
    }

    private fun containsNormalized(values: List<String>, candidate: String): Boolean {
        val wanted = normalizedName(candidate)
        return values.any { normalizedName(it) == wanted }
    }
}

/** The case-insensitive comparison form used for entry and tombstone ids. */
internal fun comparableClipId(value: String): String = value.trim().lowercase()
