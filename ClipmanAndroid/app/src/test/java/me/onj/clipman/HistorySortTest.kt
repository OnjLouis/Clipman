package me.onj.clipman

import org.junit.Assert.assertEquals
import org.junit.Test

class HistorySortTest {
    @Test
    fun missingOrUnknownStoredValuesDefaultToManual() {
        assertEquals(HistorySort.Manual, HistorySort.fromStoredValue(null))
        assertEquals(HistorySort.Manual, HistorySort.fromStoredValue(""))
        assertEquals(HistorySort.Manual, HistorySort.fromStoredValue("unexpected"))
    }

    @Test
    fun storedValuesNormalizeWhitespaceAndCase() {
        assertEquals(HistorySort.Manual, HistorySort.fromStoredValue(" MANUAL "))
        assertEquals(HistorySort.Newest, HistorySort.fromStoredValue(" Newest "))
        assertEquals(HistorySort.Oldest, HistorySort.fromStoredValue("OLDEST"))
        assertEquals(HistorySort.Text, HistorySort.fromStoredValue("text"))
    }

    @Test
    fun accessibilityActionsHaveStableExplicitOrder() {
        assertEquals(
            listOf(
                "Set sort to Manual",
                "Set sort to Newest first",
                "Set sort to Oldest first",
                "Set sort to Text"
            ),
            historySortAccessibilityActionLabels()
        )
    }
}
