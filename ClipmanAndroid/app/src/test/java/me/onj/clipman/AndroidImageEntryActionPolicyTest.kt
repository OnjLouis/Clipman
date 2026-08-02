package me.onj.clipman

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64

class AndroidImageEntryActionPolicyTest {
    private val onePixelPng = Base64.getDecoder().decode(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2nWQAAAAASUVORK5CYII="
    )

    @Test
    fun preservesUsefulStoredFilename() {
        val image = EmbeddedImageData("Holiday photo.png", "Image", "image/png", onePixelPng, 1, 1, true)
        assertEquals(
            "Holiday photo.png",
            AndroidImageEntryActionPolicy.exportFilename(image, "Android phone", 1_754_041_506_000)
        )
    }

    @Test
    fun genericFilenameIncludesDateAndSanitizedDevice() {
        val image = EmbeddedImageData("Clipboard image.png", "Image", "image/png", onePixelPng, 1, 1, true)
        val filename = AndroidImageEntryActionPolicy.exportFilename(image, "Andre's/Phone", 1_754_041_506_000)
        assertTrue(filename.startsWith("Clipman image "))
        assertTrue(filename.contains("Andre_s_Phone"))
        assertTrue(filename.endsWith(".png"))
        assertTrue('/' !in filename)
    }

    @Test
    fun rejectsUnsupportedOrMismatchedImageData() {
        assertThrows(IllegalArgumentException::class.java) {
            AndroidImageEntryActionPolicy.validateImage(
                EmbeddedImageData("photo.gif", "Image", "image/gif", onePixelPng, 1, 1, true)
            )
        }
        assertThrows(IllegalArgumentException::class.java) {
            AndroidImageEntryActionPolicy.validateImage(
                EmbeddedImageData("photo.jpg", "Image", "image/jpeg", onePixelPng, 1, 1, true)
            )
        }
    }
}
