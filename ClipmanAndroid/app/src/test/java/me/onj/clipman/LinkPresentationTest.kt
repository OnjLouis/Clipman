package me.onj.clipman

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LinkPresentationTest {
    @Test
    fun offlineLabelUsesHostAndDecodedMeaningfulPath() {
        val url = "https://www.ableton.com/en/release-notes/move-1-beta/"

        assertEquals("Move 1 beta", LinkPresentation.offlineLabel(url))
        assertEquals("ableton.com/en/release-notes/move-1-beta", LinkPresentation.shortenedDestination(url))
    }

    @Test
    fun issueNumberAndDatedArticleLabelsMatchCrossPlatformContract() {
        val issue = "https://github.com/OnjLouis/Clipman/issues/50"
        val article = "https://example.com/2024/03/how-to-fix-the-thing"

        assertEquals("Issues 50", LinkPresentation.offlineLabel(issue))
        assertEquals("Issues 50; github.com/OnjLouis/Clipman/issues/50", LinkPresentation.rowText(ClipEntry(Text = issue)))
        assertEquals("How to fix the thing", LinkPresentation.offlineLabel(article))
        assertEquals(
            "How to fix the thing; example.com/2024/03/how-to-fix-the-thing",
            LinkPresentation.rowText(ClipEntry(Text = article))
        )
        assertEquals("example.com", LinkPresentation.offlineLabel("https://www.example.com/"))
        assertEquals("example.com", LinkPresentation.rowText(ClipEntry(Text = "https://www.example.com/")))
    }

    @Test
    fun nameWinsWithoutChangingOriginalUrl() {
        val url = "https://example.org/articles/screen-reader-access"
        val entry = ClipEntry(Text = url, Name = "Doug proposal")

        assertEquals(
            "Doug proposal; example.org/articles/screen-reader-access",
            LinkPresentation.rowText(entry)
        )
        assertEquals(url, entry.Text)
    }

    @Test
    fun trailingScreenReaderLinkRoleDoesNotMoveANamedUrlIntoTextHistory() {
        val stored = "https://youtu.be/Mu1gjX5fMA4  link"
        val entry = ClipEntry(Text = stored, Name = "Wooden Flute")

        assertTrue(LinkPresentation.isStandaloneLink(stored))
        assertEquals("https://youtu.be/Mu1gjX5fMA4", LinkPresentation.standaloneUrlText(stored))
        assertEquals("Wooden Flute; youtu.be/Mu1gjX5fMA4", LinkPresentation.rowText(entry))
        assertEquals(stored, entry.Text)
        assertFalse(LinkPresentation.isStandaloneLink("Read https://youtu.be/Mu1gjX5fMA4 link"))
    }

    @Test
    fun bareWebAddressesRemainLinkEntries() {
        assertTrue(LinkPresentation.isStandaloneLink("example.org/path"))
        assertEquals("Path; example.org/path", LinkPresentation.rowText(ClipEntry(Text = "example.org/path")))
    }

    @Test
    fun generatedLabelParticipatesInSearchText() {
        val entry = ClipEntry(Text = "https://example.org/news/audio-description")

        assertTrue(LinkPresentation.searchableText(entry).contains("audio description", ignoreCase = true))
    }

    @Test
    fun uuidAndHighEntropySegmentsAreSkipped() {
        val uuid = "https://example.org/files/550e8400-e29b-41d4-a716-446655440000"
        val token = "https://example.org/download/Az19Qw82Er73Ty64Ui50Op21Lm98"

        assertEquals("Files", LinkPresentation.offlineLabel(uuid))
        assertEquals("Download", LinkPresentation.offlineLabel(token))
    }

    @Test
    fun standaloneDetectionDoesNotAcceptTextAroundUrl() {
        assertTrue(LinkPresentation.isStandaloneLink("https://example.org/path"))
        assertTrue(LinkPresentation.isStandaloneLink("clipman://server.example/path"))
        assertFalse(LinkPresentation.isStandaloneLink("Read https://example.org/path"))
    }

    @Test
    fun overlongUrlsAreRejectedBeforeOfflinePresentation() {
        val prefix = "https://example.org/"
        val exact = prefix + "a".repeat(WebsiteTitlePolicy.maxUrlCharacters - prefix.length)
        val overlong = exact + "a"

        assertTrue(LinkPresentation.isStandaloneLink(exact))
        assertFalse(LinkPresentation.isStandaloneLink(overlong))
        assertNull(LinkPresentation.offlineLabel(overlong))
        assertNull(LinkPresentation.shortenedDestination(overlong))
    }

    @Test
    fun offlineLabelsStripUnsafeUnicodeAndRetainNormalUnicode() {
        val url = "https://example.org/caf%C3%A9%E2%80%8B%EF%BF%BD%0A%E2%80%A8-r%C3%A9sum%C3%A9"

        assertEquals("Café résumé", LinkPresentation.offlineLabel(url))
        assertEquals("A 日本語 B", LinkVisibleText.sanitize("A\u00a0日本語\u2003B"))
        assertEquals("AB", LinkVisibleText.sanitize("A\u0001\u200b\ud800\ufffd\u2028\u2029B"))
    }
}
