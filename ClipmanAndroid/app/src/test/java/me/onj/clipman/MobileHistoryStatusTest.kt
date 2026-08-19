package me.onj.clipman

import org.junit.Assert.assertEquals
import org.junit.Test

class MobileHistoryStatusTest {
    @Test
    fun combinesCurrentSectionCountWithConnectionState() {
        assertEquals(
            "259 text entries. Ready. Server sync connected.",
            historyStatusText(259, "Text", "Ready. Server sync connected.")
        )
        assertEquals(
            "1 link entry. Ready. Using local history.",
            historyStatusText(1, "Links", "Ready. Using local history.")
        )
        assertEquals(
            "3 rich text entries. Shared text added to Clipman history.",
            historyStatusText(3, "Rich Text", "Shared text added to Clipman history.")
        )
    }
}
