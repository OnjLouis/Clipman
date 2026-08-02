package me.onj.clipman

import java.util.Base64
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class EmbeddedImageRichTextTest {
    private val onePixelPng = Base64.getDecoder().decode(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    )

    @Test
    fun canonicalWrapperRoundTripsWithoutChangingOriginalBytes() {
        val html = EmbeddedImageRichText.wrap("photo & note.png", "Image: photo & note.png", "image/png", onePixelPng)
        val parsed = EmbeddedImageRichText.parse(RichTextPayload(HtmlFragment = html, PreferredFormat = "Html"))

        assertEquals("photo & note.png", parsed?.filename)
        assertEquals(1, parsed?.width)
        assertEquals(1, parsed?.height)
        assertArrayEquals(onePixelPng, parsed?.bytes)
    }

    @Test
    fun apostropheRemainsLiteralInDoubleQuotedAttributes() {
        val html = EmbeddedImageRichText.wrap("Andre's photo.png", "Image: Andre's photo.png", "image/png", onePixelPng)

        assertTrue(html.contains("data-clipman-filename=\"Andre's photo.png\""))
        assertTrue(html.contains("alt=\"Image: Andre's photo.png\""))
        assertFalse(html.contains("&#39;"))
        assertEquals("Andre's photo.png", EmbeddedImageRichText.parse(RichTextPayload(HtmlFragment = html))?.filename)
    }

    @Test
    fun parserRejectsColonPathsOverlongNamesAndMimeExtensionMismatch() {
        val canonical = EmbeddedImageRichText.wrap("photo.png", "Image: photo.png", "image/png", onePixelPng)
        assertNull(EmbeddedImageRichText.parse(RichTextPayload(HtmlFragment = canonical.replace("photo.png", "photo:1.png"))))
        assertNull(EmbeddedImageRichText.parse(RichTextPayload(HtmlFragment = canonical.replace("photo.png", "folder/photo.png"))))
        assertNull(EmbeddedImageRichText.parse(RichTextPayload(HtmlFragment = canonical.replace("photo.png", "folder\\photo.png"))))
        assertNull(EmbeddedImageRichText.parse(RichTextPayload(HtmlFragment = canonical.replace("photo.png", "photo.jpg"))))
        val overlong = "a".repeat(117) + ".png"
        assertNull(EmbeddedImageRichText.parse(RichTextPayload(HtmlFragment = canonical.replace("photo.png", overlong))))
    }

    @Test
    fun writerRemovesColonBeforeCanonicalStorage() {
        val html = EmbeddedImageRichText.wrap("camera:photo.png", "Image: cameraphoto.png", "image/png", onePixelPng)

        assertEquals("cameraphoto.png", EmbeddedImageRichText.parse(RichTextPayload(HtmlFragment = html))?.filename)
    }

    @Test
    fun writerLowercasesImageSuffixAndParserRejectsUppercaseSuffix() {
        val html = EmbeddedImageRichText.wrap("PHOTO.PNG", "Image: PHOTO.png", "image/png", onePixelPng)
        assertEquals("PHOTO.png", EmbeddedImageRichText.parse(RichTextPayload(HtmlFragment = html))?.filename)

        val uppercaseWrapper = html.replace("PHOTO.png", "PHOTO.PNG")
        assertNull(EmbeddedImageRichText.parse(RichTextPayload(HtmlFragment = uppercaseWrapper)))
    }

    @Test
    fun filenameLimitCountsUnicodeScalarsAndPreservesExtension() {
        val atLimit = "😀".repeat(116) + ".png"
        val html = EmbeddedImageRichText.wrap(atLimit, "Image: $atLimit", "image/png", onePixelPng)
        assertEquals(120, EmbeddedImageRichText.parse(RichTextPayload(HtmlFragment = html))?.filename?.codePointCount(0, atLimit.length))

        val overLimit = "😀".repeat(117) + ".png"
        val noncanonical = html.replace(atLimit, overLimit)
        assertNull(EmbeddedImageRichText.parse(RichTextPayload(HtmlFragment = noncanonical)))

        val normalized = EmbeddedImageRichText.normalizeFilename(overLimit, "image/png")
        assertEquals(120, normalized.codePointCount(0, normalized.length))
        assertTrue(normalized.endsWith(".png"))
    }

    @Test
    fun parserRejectsControlFormatAndBidiControls() {
        val canonical = EmbeddedImageRichText.wrap("photo.png", "Image: photo.png", "image/png", onePixelPng)
        listOf("photo\u0001.png", "photo\u200b.png", "photo\u202e.png", "photo\u2067.png").forEach { unsafe ->
            assertNull(EmbeddedImageRichText.parse(RichTextPayload(HtmlFragment = canonical.replace("photo.png", unsafe))))
        }
    }

    @Test
    fun filenamesCollapseAllUnicodeWhitespaceAndRejectNoncanonicalWrappers() {
        listOf("\t", "\n", "\u00a0", "\u2003", "\u2028", "\u2029").forEach { whitespace ->
            val normalized = EmbeddedImageRichText.normalizeFilename("photo${whitespace}${whitespace}note.png", "image/png")
            assertEquals("photo note.png", normalized)
        }
        assertEquals("photonote.png", EmbeddedImageRichText.normalizeFilename("photo\u001cnote.png", "image/png"))

        val canonical = EmbeddedImageRichText.wrap("photo note.png", "Image: photo note.png", "image/png", onePixelPng)
        listOf('\u2028', '\u2029').forEach { separator ->
            val unsafe = canonical.replace("photo note.png", "photo${separator}note.png")
            assertNull(EmbeddedImageRichText.parse(RichTextPayload(HtmlFragment = unsafe)))
        }

        val replacement = canonical.replace("photo note.png", "photo\ufffdnote.png")
        assertNull(EmbeddedImageRichText.parse(RichTextPayload(HtmlFragment = replacement)))
        assertEquals(
            "photonote.png",
            EmbeddedImageRichText.normalizeFilename("photo\ufffdnote.png", "image/png")
        )
    }

    @Test
    fun filenamesAreBasenamesAndFallbackIdentityUsesFinalBytes() {
        val html = EmbeddedImageRichText.wrap(
            "C:\\private\\camera\\photo.png",
            "Image: photo.png",
            "image/png",
            onePixelPng
        )
        val parsed = EmbeddedImageRichText.parse(RichTextPayload(HtmlFragment = html, PreferredFormat = "Html"))

        assertEquals("photo.png", parsed?.filename)
        assertEquals("Image: photo.png (431ced6916a2)", EmbeddedImageRichText.fallbackText("/private/photo.png", onePixelPng))
        assertFalse(html.contains("private"))
    }

    @Test
    fun externalActiveAndNoncanonicalWrappersAreRejected() {
        assertNull(
            EmbeddedImageRichText.parse(
                RichTextPayload(HtmlFragment = "<img data-clipman-image=\"1\" src=\"https://example.org/a.png\">")
            )
        )
        val canonical = EmbeddedImageRichText.wrap("photo.png", "Image: photo.png", "image/png", onePixelPng)
        assertNull(EmbeddedImageRichText.parse(RichTextPayload(HtmlFragment = canonical.replace("<img ", "<img onclick=\"x\" "))))
        assertNull(EmbeddedImageRichText.parse(RichTextPayload(HtmlFragment = canonical + "<script>alert(1)</script>")))
    }

    @Test
    fun animatedAndOversizedDimensionsAreRejected() {
        val animated = pngWithDimensions(1, 1, animated = true)
        assertThrows(IllegalArgumentException::class.java) {
            EmbeddedImageRichText.wrap("animated.png", "Image: animated.png", "image/png", animated)
        }

        val tooWide = pngWithDimensions(2049, 1, animated = false)
        assertThrows(IllegalArgumentException::class.java) {
            EmbeddedImageRichText.wrap("wide.png", "Image: wide.png", "image/png", tooWide)
        }
    }

    @Test
    fun imageBudgetCountsOnlyStrictEmbeddedImages() {
        val html = EmbeddedImageRichText.wrap("photo.png", "Image: photo.png", "image/png", onePixelPng)
        val entries = listOf(
            ClipEntry(Text = "image", RichText = RichTextPayload(HtmlFragment = html)),
            ClipEntry(Text = "normal", RichText = RichTextPayload(HtmlFragment = "<b>normal</b>"))
        )

        assertEquals(onePixelPng.size.toLong(), EmbeddedImageRichText.totalStoredBytes(entries))
        assertTrue(EmbeddedImageRichText.fallbackText("photo.png", onePixelPng).matches(Regex("Image: photo\\.png \\([0-9a-f]{12}\\)")))
    }

    @Test
    fun existingEmbeddedImageWriteIgnoresCaptureSettingsAndKeepsFallbacks() {
        listOf(
            Triple("photo.png", "image/png", onePixelPng),
            Triple("photo.jpg", "image/jpeg", onePixelJpeg)
        ).forEach { (filename, mimeType, bytes) ->
            val fallback = EmbeddedImageRichText.fallbackText(filename, bytes)
            val html = EmbeddedImageRichText.wrap(filename, "Image: $filename", mimeType, bytes)
            val entry = ClipEntry(
                Text = fallback,
                RichText = RichTextPayload(HtmlFragment = html, PreferredFormat = "Html")
            )

            val disabledPlan = RichTextClipboard.planWrite(entry, includeRichText = false)
            assertEquals(fallback, disabledPlan.plainText)
            assertEquals(html, disabledPlan.html)
            assertEquals(mimeType, disabledPlan.embeddedImage?.mimeType)
            assertArrayEquals(bytes, disabledPlan.embeddedImage?.bytes)

            val enabledPlan = RichTextClipboard.planWrite(entry, includeRichText = true)
            assertEquals(disabledPlan.plainText, enabledPlan.plainText)
            assertEquals(disabledPlan.html, enabledPlan.html)
            assertEquals(disabledPlan.embeddedImage?.mimeType, enabledPlan.embeddedImage?.mimeType)
            assertArrayEquals(disabledPlan.embeddedImage?.bytes, enabledPlan.embeddedImage?.bytes)
        }
    }

    @Test
    fun ordinaryRichTextStillHonorsRichTextSettingWhenCopied() {
        val entry = ClipEntry(
            Text = "Formatted text",
            RichText = RichTextPayload(HtmlFragment = "<b>Formatted text</b>", PreferredFormat = "Html")
        )

        assertNull(RichTextClipboard.planWrite(entry, includeRichText = false).html)
        assertEquals("<b>Formatted text</b>", RichTextClipboard.planWrite(entry, includeRichText = true).html)
    }

    @Test
    fun inputAndTotalBudgetLimitsAreExplicit() {
        assertTrue(EmbeddedImageRichText.isWithinInputLimits(1024, 4000, 4000))
        assertFalse(EmbeddedImageRichText.isWithinInputLimits(EmbeddedImageRichText.maxInputBytes + 1, 1, 1))
        assertFalse(EmbeddedImageRichText.isWithinInputLimits(1024, 4097, 1))
        assertFalse(EmbeddedImageRichText.isWithinInputLimits(1024, 4001, 4000))

        val html = EmbeddedImageRichText.wrap("photo.png", "Image: photo.png", "image/png", onePixelPng)
        val existing = ClipEntry(
            Text = EmbeddedImageRichText.fallbackText("photo.png", onePixelPng),
            RichText = RichTextPayload(HtmlFragment = html)
        )
        assertFalse(EmbeddedImageRichText.exceedsTotalBudget(listOf(existing), existing.Text, onePixelPng.size))
        assertTrue(EmbeddedImageRichText.exceedsTotalBudget(emptyList(), "new image", EmbeddedImageRichText.totalImageBudgetBytes + 1))
    }

    @Test
    fun boundedPngMetadataCanBePreservedDuringReencoding() {
        val metadataChunk = chunk("tEXt", "Camera=Example;Location=Example".toByteArray(Charsets.ISO_8859_1))
        val source = onePixelPng.copyOfRange(0, 33) + metadataChunk + onePixelPng.copyOfRange(33, onePixelPng.size)
        val metadata = BoundedImageMetadata.extract(source, "image/png")

        assertEquals(1, metadata.size)
        assertArrayEquals(metadataChunk, metadata.single())
        val reinjected = BoundedImageMetadata.inject(onePixelPng, "image/png", metadata)
        assertArrayEquals(metadataChunk, BoundedImageMetadata.extract(reinjected, "image/png").single())
    }

    private fun pngWithDimensions(width: Int, height: Int, animated: Boolean): ByteArray {
        val signature = byteArrayOf(0x89.toByte(), 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a)
        val ihdr = chunk("IHDR", byteArrayOf(
            (width ushr 24).toByte(), (width ushr 16).toByte(), (width ushr 8).toByte(), width.toByte(),
            (height ushr 24).toByte(), (height ushr 16).toByte(), (height ushr 8).toByte(), height.toByte(),
            8, 6, 0, 0, 0
        ))
        val animation = if (animated) chunk("acTL", byteArrayOf(0, 0, 0, 1, 0, 0, 0, 0)) else ByteArray(0)
        val end = chunk("IEND", ByteArray(0))
        return signature + ihdr + animation + end
    }

    private val onePixelJpeg = byteArrayOf(
        0xff.toByte(), 0xd8.toByte(),
        0xff.toByte(), 0xc0.toByte(), 0x00, 0x11, 0x08,
        0x00, 0x01, 0x00, 0x01, 0x03,
        0x01, 0x11, 0x00, 0x02, 0x11, 0x00, 0x03, 0x11, 0x00,
        0xff.toByte(), 0xd9.toByte()
    )

    private fun chunk(type: String, data: ByteArray): ByteArray {
        val length = data.size
        return byteArrayOf(
            (length ushr 24).toByte(), (length ushr 16).toByte(), (length ushr 8).toByte(), length.toByte()
        ) + type.toByteArray(Charsets.US_ASCII) + data + ByteArray(4)
    }
}
