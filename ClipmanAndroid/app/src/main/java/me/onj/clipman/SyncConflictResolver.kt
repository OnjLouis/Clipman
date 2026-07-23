package me.onj.clipman

import java.security.MessageDigest
import java.util.UUID

object SyncConflictResolver {
    fun merge(target: ClipDatabase, source: ClipDatabase): ClipDatabase {
        val deletedById = (target.DeletedEntries + source.DeletedEntries)
            .filter { it.Id.isNotBlank() }
            .groupBy { it.Id }
            .mapValues { (_, markers) -> markers.maxBy { it.DeletedUnixMs } }
            .values
            .toList()
        val retainedTarget = target.Entries.filterNot { isDeleted(it, deletedById) }
        val byId = retainedTarget.associateBy { it.Id }.toMutableMap()
        val byText = retainedTarget.associateBy { it.Text }.toMutableMap()
        val merged = retainedTarget.toMutableList()

        for (incoming in source.Entries) {
            if (incoming.Text.isEmpty()) continue
            if (isDeleted(incoming, deletedById)) continue
            val existing = byId[incoming.Id].takeUnless { incoming.Id.isBlank() } ?: byText[incoming.Text]
            if (existing == null) {
                val normalized = incoming.normalized()
                merged.add(normalized)
                if (normalized.Id.isNotBlank()) byId[normalized.Id] = normalized
                byText[normalized.Text] = normalized
            } else {
                val index = merged.indexOfFirst { it === existing || it.Id == existing.Id || it.Text == existing.Text }
                val updated = mergeEntry(existing, incoming)
                if (index >= 0) merged[index] = updated
                if (updated.Id.isNotBlank()) byId[updated.Id] = updated
                byText[updated.Text] = updated
            }
        }

        return normalize(target.copy(Entries = merged, DeletedEntries = deletedById))
    }

    fun hasSameContent(left: ClipDatabase, right: ClipDatabase): Boolean =
        left.Entries == right.Entries && left.DeletedEntries == right.DeletedEntries

    fun addText(database: ClipDatabase, text: String, machineName: String): ClipDatabase {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return database
        val now = TimeUtil.nowUnixMs()
        val withoutDuplicate = database.Entries.filterNot { it.Text == trimmed }
        val nextManualOrder = withoutDuplicate.maxOfOrNull { it.ManualOrder }?.plus(1) ?: 1
        val entry = ClipEntry(
            Id = UUID.randomUUID().toString().replace("-", ""),
            Text = trimmed,
            SourceMachine = machineName,
            CreatedUnixMs = now,
            LastUsedUnixMs = now,
            ManualOrder = nextManualOrder
        )
        return normalize(database.copy(Entries = withoutDuplicate + entry, UpdatedUnixMs = now))
    }

    fun updateEntry(database: ClipDatabase, entry: ClipEntry): ClipDatabase {
        if (entry.Id.isBlank()) return database
        val now = TimeUtil.nowUnixMs()
        val updated = entry.copy(
            Text = entry.Text.trim(),
            Name = entry.Name.trim(),
            Group = entry.Group.trim(),
            SourceMachine = entry.SourceMachine.trim(),
            LastUsedUnixMs = now
        )
        if (updated.Text.isBlank()) return deleteEntry(database, entry.Id)
        return normalize(database.copy(
            Entries = database.Entries.map { if (it.Id == entry.Id) updated else it },
            UpdatedUnixMs = now
        ))
    }

    fun togglePinned(database: ClipDatabase, entryId: String): ClipDatabase {
        val now = TimeUtil.nowUnixMs()
        return normalize(database.copy(
            Entries = database.Entries.map {
                if (it.Id == entryId) it.copy(Pinned = !it.Pinned, LastUsedUnixMs = now) else it
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

    private fun isDeleted(entry: ClipEntry, deletedEntries: List<DeletedClipEntry>): Boolean {
        val hash = textHash(entry.Text)
        val entryChangedUnixMs = maxOf(entry.CreatedUnixMs, entry.LastUsedUnixMs)
        return deletedEntries.any {
            it.Id == entry.Id ||
                (it.TextHash.isNotBlank() &&
                    it.TextHash == hash &&
                    (it.DeletedUnixMs <= 0 || entryChangedUnixMs <= it.DeletedUnixMs))
        }
    }

    private fun mergeEntry(existing: ClipEntry, incoming: ClipEntry): ClipEntry {
        val incomingWins = incoming.LastUsedUnixMs >= existing.LastUsedUnixMs
        val incomingCreatedWins = incoming.CreatedUnixMs > existing.CreatedUnixMs
        return existing.copy(
            CreatedUnixMs = when {
                incoming.CreatedUnixMs == 0L -> existing.CreatedUnixMs
                existing.CreatedUnixMs == 0L -> incoming.CreatedUnixMs
                incomingCreatedWins -> incoming.CreatedUnixMs
                !incomingWins && incoming.CreatedUnixMs < existing.CreatedUnixMs -> incoming.CreatedUnixMs
                else -> existing.CreatedUnixMs
            },
            LastUsedUnixMs = maxOf(existing.LastUsedUnixMs, incoming.LastUsedUnixMs),
            Name = if (incoming.Name.isNotBlank() && incomingWins) incoming.Name.trim() else existing.Name,
            Group = if (incoming.Group.isNotBlank() && incomingWins) incoming.Group.trim() else existing.Group,
            SourceMachine = if (incoming.SourceMachine.isNotBlank() && (incomingWins || incomingCreatedWins)) incoming.SourceMachine.trim() else existing.SourceMachine,
            Pinned = existing.Pinned || incoming.Pinned,
            IsTemplate = existing.IsTemplate || incoming.IsTemplate,
            ManualOrder = when {
                existing.ManualOrder <= 0L -> incoming.ManualOrder
                incoming.ManualOrder > 0L && incoming.ManualOrder < existing.ManualOrder -> incoming.ManualOrder
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
            Entries = normalized
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
