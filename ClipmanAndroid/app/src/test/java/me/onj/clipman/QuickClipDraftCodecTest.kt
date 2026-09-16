package me.onj.clipman

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class QuickClipDraftCodecTest {
    @Test
    fun draftRoundTripsWithoutLosingMultilineTextOrProperties() {
        val draft = ClipEntry(
            Id = "draft-id",
            Text = "First line\nResearch still to add",
            Name = "Holiday notes",
            Group = "Personal",
            Pinned = true
        )

        assertEquals(draft, QuickClipDraftCodec.decode(QuickClipDraftCodec.encode(draft)))
    }

    @Test
    fun corruptDraftIsIgnored() {
        assertNull(QuickClipDraftCodec.decode("not json"))
    }
}
