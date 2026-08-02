package me.onj.clipman

import java.util.Base64
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidImageShareTest {
    private val onePixelPng = Base64.getDecoder().decode(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    )

    @Test
    fun acceptsExactlyOneImageSend() {
        assertNull(AndroidImageSharePolicy.rejectionMessage(AndroidImageSharePolicy.actionSend, "image/jpeg", 1))
        assertNull(AndroidImageSharePolicy.rejectionMessage(AndroidImageSharePolicy.actionSend, "image/*", 1))
    }

    @Test
    fun rejectsMissingMultipleAndUnsupportedShares() {
        assertEquals(
            "The shared photo does not contain readable image data.",
            AndroidImageSharePolicy.rejectionMessage(AndroidImageSharePolicy.actionSend, "image/png", 0)
        )
        assertEquals(
            "Clipman can add one shared photo at a time.",
            AndroidImageSharePolicy.rejectionMessage(AndroidImageSharePolicy.actionSend, "image/png", 2)
        )
        assertEquals(
            "Clipman can add one shared photo at a time.",
            AndroidImageSharePolicy.rejectionMessage(AndroidImageSharePolicy.actionSendMultiple, "image/png", 1)
        )
        assertEquals(
            "Share a photo in PNG or JPEG format to Clipman.",
            AndroidImageSharePolicy.rejectionMessage(AndroidImageSharePolicy.actionSend, "text/plain", 1)
        )
        assertEquals(
            "This share action is not supported by Clipman.",
            AndroidImageSharePolicy.rejectionMessage("android.intent.action.VIEW", "image/png", 1)
        )
    }

    @Test
    fun preparedShareUsesCanonicalEmbeddedImageAndDatabaseBudget() {
        val image = EmbeddedImageData("photo.png", "Image: photo.png", "image/png", onePixelPng, 1, 1, true)
        val content = AndroidImageClipboard.contentForPreparedImage(image, emptyList())
        val parsed = EmbeddedImageRichText.parse(content.richText)

        assertEquals("photo.png", parsed?.filename)
        assertTrue(content.text.startsWith("Image: photo.png ("))

        val fullSizePng = onePixelPng.copyOf(EmbeddedImageRichText.maxStoredImageBytes)
        val fullHtml = EmbeddedImageRichText.wrap("stored.png", "Image: stored.png", "image/png", fullSizePng)
        val fullEntries = List(
            EmbeddedImageRichText.totalImageBudgetBytes / EmbeddedImageRichText.maxStoredImageBytes
        ) { index ->
            ClipEntry(Id = "stored-$index", Text = "stored-$index", RichText = RichTextPayload(HtmlFragment = fullHtml))
        }
        assertThrows(ImageClipboardException::class.java) {
            AndroidImageClipboard.contentForPreparedImage(image, fullEntries)
        }
    }
}
