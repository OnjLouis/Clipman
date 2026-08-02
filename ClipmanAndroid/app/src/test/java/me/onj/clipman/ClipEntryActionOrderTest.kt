package me.onj.clipman

import org.junit.Assert.assertEquals
import org.junit.Test

class ClipEntryActionOrderTest {
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
