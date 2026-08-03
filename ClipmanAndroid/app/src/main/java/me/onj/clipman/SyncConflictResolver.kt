package me.onj.clipman

import java.security.MessageDigest
import java.util.UUID

object SyncConflictResolver {
    fun merge(target: ClipDatabase, source: ClipDatabase): ClipDatabase {
        val deletedById = normalizeDeletedEntries(target.DeletedEntries + source.DeletedEntries)
            .filter { it.Id.isNotBlank() }
            .groupBy { it.Id }
            .mapValues { (_, markers) -> markers.maxBy { it.DeletedUnixMs } }
            .values
            .toList()
        val deletionIndex = DeletionIndex(deletedById)
        val retainedTarget = target.Entries.filterNot { deletionIndex.contains(it) }
        val byId = retainedTarget.associateBy { it.Id }.toMutableMap()
        val byText = retainedTarget.associateBy { it.Text }.toMutableMap()
        val merged = retainedTarget.toMutableList()

        for (incoming in source.Entries) {
            if (incoming.Text.isEmpty()) continue
            if (deletionIndex.contains(incoming)) continue
            val existing = byId[incoming.Id].takeUnless { incoming.Id.isBlank() } ?: byText[incoming.Text]
            if (existing == null) {
                val normalized = incoming.normalized()
                merged.add(normalized)
                if (normalized.Id.isNotBlank()) byId[normalized.Id] = normalized
                byText[normalized.Text] = normalized
            } else {
                val index = merged.indexOfFirst { it === existing || it.Id == existing.Id || it.Text == existing.Text }
                val previousText = existing.Text
                val updated = mergeEntry(existing, incoming)
                if (index >= 0) merged[index] = updated
                if (updated.Id.isNotBlank()) byId[updated.Id] = updated
                if (previousText != updated.Text) byText.remove(previousText)
                byText[updated.Text] = updated
            }
        }

        return normalize(target.copy(Entries = merged, DeletedEntries = deletedById))
    }

    fun hasSameContent(left: ClipDatabase, right: ClipDatabase): Boolean =
        left.Entries == right.Entries && left.DeletedEntries == right.DeletedEntries

    fun addText(database: ClipDatabase, text: String, machineName: String, richText: RichTextPayload? = null): ClipDatabase {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return database
        val now = TimeUtil.nowUnixMs()
        val existing = database.Entries.firstOrNull { it.Text == trimmed }
        val normalizedRichText = RichTextClipboard.normalize(richText)
        val storedRichText = normalizedRichText ?: existing?.RichText
        val richTextUpdated = if (normalizedRichText == null) existing?.RichTextUpdatedUnixMs ?: 0 else now
        val withoutDuplicate = database.Entries.filterNot { it.Text == trimmed }
        val nextManualOrder = withoutDuplicate.maxOfOrNull { it.ManualOrder }?.plus(1) ?: 1
        val entry = ClipEntry(
            Id = UUID.randomUUID().toString().replace("-", ""),
            Text = trimmed,
            SourceMachine = machineName,
            CreatedUnixMs = now,
            LastUsedUnixMs = now,
            ModifiedUnixMs = now,
            ManualOrder = nextManualOrder,
            RichText = storedRichText,
            RichTextUpdatedUnixMs = richTextUpdated
        )
        return normalize(database.copy(Entries = withoutDuplicate + entry, UpdatedUnixMs = now))
    }

    fun updateEntry(database: ClipDatabase, entry: ClipEntry): ClipDatabase {
        if (entry.Id.isBlank()) return database
        val now = TimeUtil.nowUnixMs()
        val requestedGroup = entry.Group.trim()
        val normalizedGroup = canonicalGroup(database.Entries, requestedGroup)
        val updated = entry.copy(
            Text = entry.Text.trim(),
            Name = entry.Name.trim(),
            Group = normalizedGroup,
            SourceMachine = entry.SourceMachine.trim(),
            LastUsedUnixMs = now,
            ModifiedUnixMs = now,
            RichText = if (entry.Text.trim() == database.Entries.firstOrNull { it.Id == entry.Id }?.Text) entry.RichText else null,
            RichTextUpdatedUnixMs = if (entry.Text.trim() == database.Entries.firstOrNull { it.Id == entry.Id }?.Text) entry.RichTextUpdatedUnixMs else now
        )
        if (updated.Text.isBlank()) return deleteEntry(database, entry.Id)
        return normalize(database.copy(
            Entries = database.Entries.map { if (it.Id == entry.Id) updated else it },
            UpdatedUnixMs = now
        ))
    }

    private fun canonicalGroup(entries: List<ClipEntry>, requested: String): String {
        if (requested.isBlank()) return ""
        return entries
            .filter { it.Group.trim().equals(requested, ignoreCase = true) }
            .groupBy { it.Group.trim() }
            .map { (label, spelling) ->
                Triple(
                    label,
                    spelling.size,
                    spelling.maxOf { maxOf(it.ModifiedUnixMs, it.LastUsedUnixMs, it.CreatedUnixMs) }
                )
            }
            .sortedWith(
                compareByDescending<Triple<String, Int, Long>> { it.second }
                    .thenByDescending { it.third }
                    .thenBy { it.first }
            )
            .firstOrNull()?.first ?: requested
    }

    fun togglePinned(database: ClipDatabase, entryId: String): ClipDatabase {
        val now = TimeUtil.nowUnixMs()
        return normalize(database.copy(
            Entries = database.Entries.map {
                if (it.Id == entryId) it.copy(Pinned = !it.Pinned, LastUsedUnixMs = now, ModifiedUnixMs = now) else it
            },
            UpdatedUnixMs = now
        ))
    }

    fun deleteEntry(database: ClipDatabase, entryId: String): ClipDatabase {
        val entry = database.Entries.firstOrNull { it.Id == entryId } ?: return database
        val now = TimeUtil.nowUnixMs()
        val deleted = DeletedClipEntry(
            Id = entry.Id,
            TextHash = textHash(entry.Text),
            DeletedUnixMs = now,
            SourceMachine = entry.SourceMachine
        )
        return normalize(database.copy(
            Entries = database.Entries.filterNot { it.Id == entryId },
            DeletedEntries = database.DeletedEntries + deleted,
            UpdatedUnixMs = now
        ))
    }

    fun textHash(text: String): String {
        val digest = MessageDigest.getInstance("SHA-256").digest((text.ifEmpty { "" }).toByteArray(Charsets.UTF_8))
        return digest.joinToString("") { "%02x".format(it) }
    }

    private class DeletionIndex(deletedEntries: List<DeletedClipEntry>) {
        private val deletedIds = deletedEntries.mapNotNullTo(mutableSetOf()) { marker ->
            marker.Id.takeIf { it.isNotBlank() }
        }
        private val latestDeletionByTextHash = buildMap {
            deletedEntries.forEach { marker ->
                if (marker.TextHash.isNotBlank()) {
                    put(marker.TextHash, maxOf(get(marker.TextHash) ?: Long.MIN_VALUE, marker.DeletedUnixMs))
                }
            }
        }

        fun contains(entry: ClipEntry): Boolean {
            if (entry.Id in deletedIds) return true
            if (entry.Text.isEmpty()) return false
            val deletedUnixMs = latestDeletionByTextHash[textHash(entry.Text)] ?: return false
            val entryChangedUnixMs = maxOf(entry.CreatedUnixMs, entry.LastUsedUnixMs)
            return deletedUnixMs <= 0 || entryChangedUnixMs <= deletedUnixMs
        }
    }

    private fun normalizeDeletedEntries(markers: List<DeletedClipEntry>): List<DeletedClipEntry> {
        val now = TimeUtil.nowUnixMs()
        val cutoff = now - 90L * 24 * 60 * 60 * 1_000
        return markers
            .asSequence()
            .map { marker ->
                marker.copy(
                    Id = marker.Id.trim(),
                    TextHash = marker.TextHash.trim(),
                    DeletedUnixMs = if (marker.DeletedUnixMs == 0L) now else marker.DeletedUnixMs
                )
            }
            .filter { it.Id.isNotEmpty() && it.DeletedUnixMs >= cutoff }
            .toList()
    }

    private fun mergeEntry(existing: ClipEntry, incoming: ClipEntry): ClipEntry {
        val incomingWins = incoming.LastUsedUnixMs >= existing.LastUsedUnixMs
        val incomingCreatedWins = incoming.CreatedUnixMs > existing.CreatedUnixMs
        val incomingModifiedWins = incoming.ModifiedUnixMs > existing.ModifiedUnixMs
        val bothLegacy = incoming.ModifiedUnixMs <= 0 && existing.ModifiedUnixMs <= 0
        val legacyTextRepair = bothLegacy && existing.Id.isNotBlank() && existing.Id.equals(incoming.Id, ignoreCase = true) && existing.Text != incoming.Text
        val textChangedByMerge = incomingModifiedWins && existing.Text != incoming.Text
        return existing.copy(
            Text = when {
                incomingModifiedWins || legacyTextRepair -> incoming.Text
                else -> existing.Text
            },
            CreatedUnixMs = when {
                incoming.CreatedUnixMs == 0L -> existing.CreatedUnixMs
                existing.CreatedUnixMs == 0L -> incoming.CreatedUnixMs
                incomingCreatedWins -> incoming.CreatedUnixMs
                !incomingWins && incoming.CreatedUnixMs < existing.CreatedUnixMs -> incoming.CreatedUnixMs
                else -> existing.CreatedUnixMs
            },
            LastUsedUnixMs = maxOf(existing.LastUsedUnixMs, incoming.LastUsedUnixMs),
            ModifiedUnixMs = if (incomingModifiedWins) incoming.ModifiedUnixMs else existing.ModifiedUnixMs,
            Name = when {
                incomingModifiedWins -> incoming.Name.trim()
                bothLegacy && incoming.Name.isNotBlank() && incomingWins -> incoming.Name.trim()
                else -> existing.Name
            },
            Group = when {
                incomingModifiedWins -> incoming.Group.trim()
                bothLegacy && incoming.Group.isNotBlank() && incomingWins -> incoming.Group.trim()
                else -> existing.Group
            },
            SourceMachine = if (incoming.SourceMachine.isNotBlank() && (incomingWins || incomingCreatedWins)) incoming.SourceMachine.trim() else existing.SourceMachine,
            Pinned = if (incomingModifiedWins) incoming.Pinned else if (bothLegacy) existing.Pinned || incoming.Pinned else existing.Pinned,
            IsTemplate = if (incomingModifiedWins) incoming.IsTemplate else if (bothLegacy) existing.IsTemplate || incoming.IsTemplate else existing.IsTemplate,
            RichText = when {
                textChangedByMerge -> incoming.RichText
                legacyTextRepair -> incoming.RichText
                incoming.RichTextUpdatedUnixMs > existing.RichTextUpdatedUnixMs -> incoming.RichText
                else -> existing.RichText
            },
            RichTextUpdatedUnixMs = when {
                textChangedByMerge -> maxOf(incoming.RichTextUpdatedUnixMs, incoming.ModifiedUnixMs)
                legacyTextRepair -> maxOf(existing.RichTextUpdatedUnixMs, incoming.RichTextUpdatedUnixMs)
                else -> maxOf(existing.RichTextUpdatedUnixMs, incoming.RichTextUpdatedUnixMs)
            },
            ManualOrder = when {
                incomingModifiedWins -> incoming.ManualOrder
                bothLegacy && existing.ManualOrder <= 0L -> incoming.ManualOrder
                bothLegacy && incoming.ManualOrder > 0L && incoming.ManualOrder < existing.ManualOrder -> incoming.ManualOrder
                else -> existing.ManualOrder
            }
        )
    }

    private fun normalize(database: ClipDatabase): ClipDatabase {
        var order = 1L
        val normalized = database.Entries
            .filter { it.Text.isNotEmpty() }
            .sortedWith(compareBy<ClipEntry> { if (it.ManualOrder <= 0) Long.MAX_VALUE else it.ManualOrder }.thenBy { it.CreatedUnixMs })
            .map { it.normalized(order++) }
        return database.copy(
            Version = maxOf(1, database.Version),
            UpdatedUnixMs = TimeUtil.nowUnixMs(),
            Entries = normalized,
            DeletedEntries = normalizeDeletedEntries(database.DeletedEntries)
        )
    }

    private fun ClipEntry.normalized(manualOrder: Long = ManualOrder): ClipEntry {
        val now = TimeUtil.nowUnixMs()
        return copy(
            Id = Id.ifBlank { UUID.randomUUID().toString().replace("-", "") },
            Text = Text,
            Name = Name,
            Group = Group,
            SourceMachine = SourceMachine,
            CreatedUnixMs = if (CreatedUnixMs == 0L) now else CreatedUnixMs,
            LastUsedUnixMs = if (LastUsedUnixMs == 0L) (if (CreatedUnixMs == 0L) now else CreatedUnixMs) else LastUsedUnixMs,
            ManualOrder = manualOrder
        )
    }
}

class ServerConflictException(message: String) : Exception(message)
