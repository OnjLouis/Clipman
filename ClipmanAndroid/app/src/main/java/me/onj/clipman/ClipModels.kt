package me.onj.clipman

import kotlinx.serialization.Serializable

@Serializable
data class ClipEntry(
    val Id: String = "",
    val Text: String = "",
    val Name: String = "",
    val Group: String = "",
    val SourceMachine: String = "",
    val CreatedUnixMs: Long = 0,
    val LastUsedUnixMs: Long = 0,
    val Pinned: Boolean = false,
    val IsTemplate: Boolean = false,
    val ManualOrder: Long = 0
) {
    val displayText: String
        get() = if (Name.isBlank()) Text else "$Name: $Text"
}

@Serializable
data class DeletedClipEntry(
    val Id: String = "",
    val TextHash: String = "",
    val DeletedUnixMs: Long = 0,
    val SourceMachine: String = ""
)

@Serializable
data class ClipDatabase(
    val Version: Int = 1,
    val UpdatedUnixMs: Long = 0,
    val Entries: List<ClipEntry> = emptyList(),
    val DeletedEntries: List<DeletedClipEntry> = emptyList()
)
