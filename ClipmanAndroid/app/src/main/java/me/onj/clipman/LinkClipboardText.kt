package me.onj.clipman

internal object LinkClipboardText {
    fun make(entry: ClipEntry, includeName: Boolean): String {
        val link = LinkPresentation.standaloneUrlText(entry.Text) ?: entry.Text.trim()
        val name = entry.Name.trim()
        return if (includeName && name.isNotEmpty()) "$name\n$link" else link
    }
}
