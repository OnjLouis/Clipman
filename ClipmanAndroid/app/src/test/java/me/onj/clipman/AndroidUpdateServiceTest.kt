package me.onj.clipman

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidUpdateServiceTest {
    @Test
    fun semanticVersionsCompareNumerically() {
        assertTrue(AndroidUpdateService.compareVersions("2.1.0", "2.0.9") > 0)
        assertTrue(AndroidUpdateService.compareVersions("2.10.0", "2.9.9") > 0)
        assertEquals(0, AndroidUpdateService.compareVersions("2.1", "2.1.0"))
        assertTrue(AndroidUpdateService.compareVersions("v3.0.0", "2.99.99") > 0)
    }

    @Test(expected = IllegalArgumentException::class)
    fun prereleaseVersionIsNotAcceptedAsAStableUpdate() {
        AndroidUpdateService.compareVersions("2.1.0-beta", "2.0.9")
    }

    @Test
    fun onlyClientReleaseTagsAreAcceptedForAndroidUpdates() {
        assertEquals("2.5.1", AndroidUpdateService.clientVersionFromTag("v2.5.1"))
        assertEquals("2.5.1", AndroidUpdateService.clientVersionFromTag("V2.5.1"))
        assertEquals(null, AndroidUpdateService.clientVersionFromTag("server-v2.5.1"))
        assertEquals(null, AndroidUpdateService.clientVersionFromTag("cli-v2.5.1"))
        assertEquals(null, AndroidUpdateService.clientVersionFromTag("2.5.1-beta"))
    }
}
