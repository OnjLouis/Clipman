package me.onj.clipman

import org.junit.Assert.assertEquals
import org.junit.Test

class MobileMutationFastPathTest {
    @Test
    fun knownRevisionUploadsDirectlyWithoutDownloading() {
        var uploadCount = 0
        var mergeCount = 0

        val result = runMutationUpload(
            expectedRevision = "revision-one",
            directUpload = {
                uploadCount += 1
                "uploaded"
            },
            conflictFallback = {
                mergeCount += 1
                "merged"
            }
        )

        assertEquals("uploaded", result)
        assertEquals(1, uploadCount)
        assertEquals(0, mergeCount)
    }

    @Test
    fun revisionConflictFallsBackToDownloadAndMerge() {
        var uploadCount = 0
        var mergeCount = 0

        val result = runMutationUpload(
            expectedRevision = "stale-revision",
            directUpload = {
                uploadCount += 1
                throw ServerConflictException("stale")
            },
            conflictFallback = {
                mergeCount += 1
                "merged"
            }
        )

        assertEquals("merged", result)
        assertEquals(1, uploadCount)
        assertEquals(1, mergeCount)
    }

    @Test
    fun unknownRevisionUsesConflictSafeMergeInsteadOfBlindUpload() {
        var uploadCount = 0
        var mergeCount = 0

        val result = runMutationUpload(
            expectedRevision = "",
            directUpload = {
                uploadCount += 1
                "uploaded"
            },
            conflictFallback = {
                mergeCount += 1
                "merged"
            }
        )

        assertEquals("merged", result)
        assertEquals(0, uploadCount)
        assertEquals(1, mergeCount)
    }
}
