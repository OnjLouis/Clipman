package me.onj.clipman

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AndroidTextShareTest {
    @Test
    fun acceptsSharedPlainTextAndLinks() {
        assertNull(
            AndroidTextSharePolicy.rejectionMessage(
                AndroidTextSharePolicy.actionSend,
                "text/plain",
                "https://example.com/page"
            )
        )
        assertNull(
            AndroidTextSharePolicy.rejectionMessage(
                AndroidTextSharePolicy.actionSend,
                "text/html",
                "Example page"
            )
        )
    }

    @Test
    fun rejectsEmptyOrNonTextShares() {
        assertEquals(
            "The shared item does not contain text or a link.",
            AndroidTextSharePolicy.rejectionMessage(
                AndroidTextSharePolicy.actionSend,
                "text/plain",
                "   "
            )
        )
        assertEquals(
            "Share text or a link to Clipman.",
            AndroidTextSharePolicy.rejectionMessage(
                AndroidTextSharePolicy.actionSend,
                "application/pdf",
                "Document"
            )
        )
    }
}
