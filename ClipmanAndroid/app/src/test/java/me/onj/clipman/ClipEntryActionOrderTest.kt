package me.onj.clipman

import org.junit.Assert.assertEquals
import org.junit.Test

class ClipEntryActionOrderTest {
    @Test
    fun pinnedStateIsAnnouncedBeforeClipboardText() {
        assertEquals(
            "Pinned; A long clipboard entry; Image, 640 by 480 pixels; Group: Work; Device: Phone; 2 of 8",
            clipEntryAccessibilityText(
                rowText = "A long clipboard entry",
                pinned = true,
                imageDescription = "Image, 640 by 480 pixels",
                group = "Work",
                device = "Phone",
                index = 1,
                total = 8
            )
        )
    }

    @Test
    fun unpinnedRowsBeginWithClipboardText() {
        assertEquals(
            "Clipboard entry; 1 of 1",
            clipEntryAccessibilityText(
                rowText = "Clipboard entry",
                pinned = false,
                imageDescription = null,
                group = "",
                device = "",
                index = 0,
                total = 1
            )
        )
    }

    @Test
    fun allAvailableActionsMatchTheCrossPlatformOrder() {
        assertEquals(
            listOf("Open", "View", "Edit", "Use Website Title as Name", "Pin", "Delete"),
            clipEntryActionSpecs(canOpen = true, canUseWebsiteTitle = true, pinned = false).map { it.label }
        )
    }

    @Test
    fun optionalActionsDisappearWithoutChangingTheRemainingOrder() {
        assertEquals(
            listOf("View", "Edit", "Unpin", "Delete"),
            clipEntryActionSpecs(canOpen = false, canUseWebsiteTitle = false, pinned = true).map { it.label }
        )
    }

    @Test
    fun embeddedImageActionsFollowTheCoreEntryActions() {
        assertEquals(
            listOf("View", "Edit", "Pin", "Delete", "Save to Photos", "Share"),
            clipEntryActionSpecs(
                canOpen = false,
                canUseWebsiteTitle = false,
                pinned = false,
                hasEmbeddedImage = true
            ).map { it.label }
        )
    }

    @Test
    fun nonImageEntriesDoNotExposeImageActions() {
        assertEquals(
            listOf("View", "Edit", "Pin", "Delete"),
            clipEntryActionSpecs(
                canOpen = false,
                canUseWebsiteTitle = false,
                pinned = false,
                hasEmbeddedImage = false
            ).map { it.label }
        )
    }
}
