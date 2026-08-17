package me.onj.clipman

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HistoryRowPreviewTest {
    @Test
    fun longEntryUsesBoundedPreviewWithoutChangingStoredText() {
        val fullText = "Long clipboard content ".repeat(10_000)
        val entry = ClipEntry(Id = "long", Text = fullText)

        val preview = historyRowPreview(entry)
        assertEquals(fullText, entry.Text)
        assertTrue(preview.wasTruncated)
        assertTrue(preview.text.codePointCount(0, preview.text.length) <= HistoryRowPreview.maximumCodePoints + 3)
        assertFalse(preview.text.contains(fullText))
    }

    @Test
    fun nameAndTextShareOneBoundedRowBudget() {
        val entry = ClipEntry(
            Id = "named",
            Text = "T".repeat(50_000),
            Name = "Invoice date"
        )

        val preview = historyRowPreview(entry)
        assertTrue(preview.text.startsWith("Invoice date: "))
        assertTrue(preview.wasTruncated)
        assertTrue(preview.text.codePointCount(0, preview.text.length) <= HistoryRowPreview.maximumCodePoints + 3)
    }

    @Test
    fun ordinaryEntryIsNotMarkedAsTruncated() {
        val preview = historyRowPreview(ClipEntry(Id = "short", Text = "Short clipboard entry"))

        assertEquals("Short clipboard entry", preview.text)
        assertFalse(preview.wasTruncated)
    }

    @Test
    fun oversizedTextIsNotScannedForPerRowLinkActions() {
        val text = "https://example.com/" + "x".repeat(HistoryRowPreview.maximumLinkInspectionCodePoints)

        assertFalse(HistoryRowPreview.canInspectLinks(text))
        assertTrue(extractLinksForHistoryRow(text).isEmpty())
    }

    @Test
    fun talkBackReceivesOnlyTheBoundedPreview() {
        val fullText = "A".repeat(100_000)
        val preview = historyRowPreview(ClipEntry(Text = fullText))
        val spoken = clipEntryAccessibilityText(
            rowText = preview.text,
            previewWasTruncated = preview.wasTruncated,
            pinned = false,
            imageDescription = null,
            group = "",
            device = "",
            index = 0,
            total = 1
        )

        assertTrue(spoken.contains("Preview truncated"))
        assertFalse(spoken.contains(fullText))
    }

    @Test
    fun previewDoesNotSplitSupplementaryCharacters() {
        val text = "\uD83D\uDE00".repeat(HistoryRowPreview.maximumCodePoints + 1)
        val preview = HistoryRowPreview.make(text)

        assertTrue(preview.wasTruncated)
        assertEquals(HistoryRowPreview.maximumCodePoints + 3, preview.text.codePointCount(0, preview.text.length))
    }
}
