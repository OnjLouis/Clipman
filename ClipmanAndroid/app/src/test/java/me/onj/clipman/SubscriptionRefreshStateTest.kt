package me.onj.clipman

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SubscriptionRefreshStateTest {
    @Test
    fun subscriptionChangeInvalidatesEveryCachedChannelRevision() {
        val previous = ChannelSyncState(
            RulesRevision = "rules-old",
            Channels = listOf(
                ChannelSyncRecord(Key = "", Revision = "core-revision", Exists = true),
                ChannelSyncRecord(Key = "test", Revision = "test-revision", Exists = true)
            )
        )

        val refreshed = channelStateAfterSubscriptionChange(previous, "rules-new")

        assertEquals("rules-new", refreshed.RulesRevision)
        assertTrue(refreshed.Channels.isEmpty())
    }
}
