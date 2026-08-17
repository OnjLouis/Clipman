package me.onj.clipman

internal object HistoryRowPreview {
    const val maximumCodePoints = 240
    const val maximumMetadataCodePoints = 80
    const val maximumLinkInspectionCodePoints = 16_384

    data class Value(val text: String, val wasTruncated: Boolean)

    fun make(value: String, sourceWasTruncated: Boolean = false): Value =
        clipped(value, maximumCodePoints, sourceWasTruncated)

    fun joined(name: String, nameWasTruncated: Boolean, text: String): Value {
        val nameLength = name.codePointCount(0, name.length)
        val availableText = (maximumCodePoints - nameLength - 2).coerceAtLeast(0)
        val textPreview = clipped(text, availableText)
        return Value(
            text = "$name: ${textPreview.text}",
            wasTruncated = nameWasTruncated || textPreview.wasTruncated
        )
    }

    fun metadata(value: String): String =
        LinkVisibleText.sanitize(prefix(value, maximumMetadataCodePoints), maximumMetadataCodePoints)

    fun exceedsMetadataLimit(value: String): Boolean =
        exceedsLimit(value, maximumMetadataCodePoints)

    fun canInspectLinks(value: String): Boolean =
        !exceedsLimit(value, maximumLinkInspectionCodePoints)

    private fun clipped(
        value: String,
        maximum: Int,
        sourceWasTruncated: Boolean = false
    ): Value {
        val visible = prefix(value, maximum.coerceAtLeast(0))
        val truncated = sourceWasTruncated || visible.length < value.length
        return Value(visible + if (truncated) "..." else "", truncated)
    }

    private fun exceedsLimit(value: String, maximum: Int): Boolean =
        prefixEnd(value, maximum.coerceAtLeast(0)) < value.length

    private fun prefix(value: String, maximum: Int): String =
        value.substring(0, prefixEnd(value, maximum.coerceAtLeast(0)))

    private fun prefixEnd(value: String, maximum: Int): Int {
        var offset = 0
        var count = 0
        while (offset < value.length && count < maximum) {
            offset += Character.charCount(value.codePointAt(offset))
            count++
        }
        return offset
    }
}

internal fun historyRowPreview(entry: ClipEntry): HistoryRowPreview.Value {
    val name = HistoryRowPreview.metadata(entry.Name)
    val nameWasTruncated = HistoryRowPreview.exceedsMetadataLimit(entry.Name)
    val image = EmbeddedImageRichText.parse(entry.RichText)
    if (image != null) {
        return HistoryRowPreview.make(
            name.ifBlank { image.altText },
            sourceWasTruncated = nameWasTruncated
        )
    }
    if (HistoryRowPreview.canInspectLinks(entry.Text) && LinkPresentation.isStandaloneLink(entry.Text)) {
        return HistoryRowPreview.make(
            LinkPresentation.rowText(entry.copy(Name = name)),
            sourceWasTruncated = nameWasTruncated
        )
    }
    return if (name.isNotBlank()) {
        HistoryRowPreview.joined(name, nameWasTruncated, entry.Text)
    } else {
        HistoryRowPreview.make(entry.Text)
    }
}
