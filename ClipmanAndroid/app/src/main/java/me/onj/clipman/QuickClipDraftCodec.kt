package me.onj.clipman

import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

internal object QuickClipDraftCodec {
    private val json = Json {
        encodeDefaults = true
        ignoreUnknownKeys = true
    }

    fun encode(draft: ClipEntry): String = json.encodeToString(draft)

    fun decode(value: String): ClipEntry? {
        if (value.isBlank()) return null
        return runCatching { json.decodeFromString<ClipEntry>(value) }.getOrNull()
    }
}
