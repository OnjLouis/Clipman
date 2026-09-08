package me.onj.clipman

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
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

    // -- Channel-aware mutations (sync-rules-spec.md section 5) ------------

    // Tombstones older than the 90 day retention window are normalized away, so
    // the fixtures are anchored to the current clock.
    private val now = TimeUtil.nowUnixMs()

    private fun entry(
        id: String,
        text: String = "text-$id",
        group: String = "",
        order: Long = 1
    ) = ClipEntry(
        Id = id,
        Text = text,
        Group = group,
        SourceMachine = "Android Pixel",
        CreatedUnixMs = now,
        LastUsedUnixMs = now,
        ModifiedUnixMs = now,
        ManualOrder = order
    )

    private val rules = SyncRulesDocument(
        Version = 1,
        Enabled = true,
        UpdatedUnixMs = now,
        UpdatedBy = "Desktop",
        Channels = listOf(
            SyncChannel(Name = "Work", Route = SyncRoute(Groups = listOf("Work"))),
            SyncChannel(Name = "Private", Route = SyncRoute(Groups = listOf("Private")))
        ),
        Devices = listOf(
            SyncDevice(Name = "Android Pixel", Channels = listOf("work"))
        )
    )

    /** A channel bucket store that records the order channels are written in. */
    private class FakeChannelTransport(initial: Map<String, ClipDatabase>) : MobileChannelTransport {
        val stored = HashMap<String, ClipDatabase>(initial)
        val revisions = HashMap<String, String>()
        val writes = mutableListOf<String>()
        val writeRevisions = mutableListOf<Pair<String, String>>()
        var refuse: String? = null
        private var counter = 0

        init {
            initial.keys.forEach { revisions[it] = "r0$it" }
        }

        override fun revision(channelKey: String): String = revisions[channelKey] ?: ""

        override fun read(channelKey: String): MobileChannelFetch? {
            val database = stored[channelKey] ?: return null
            return MobileChannelFetch(database, revisions[channelKey] ?: "", null)
        }

        override fun write(
            channelKey: String,
            database: ClipDatabase,
            expectedRevision: String,
            exists: Boolean
        ): MobileChannelWriteResult {
            if (channelKey == refuse) throw IllegalStateException("Clipman Server refused the $channelKey channel.")
            writes.add(channelKey)
            writeRevisions.add(channelKey to expectedRevision)
            stored[channelKey] = database
            counter += 1
            val revision = "r$counter$channelKey"
            revisions[channelKey] = revision
            return MobileChannelWriteResult(revision, null)
        }
    }

    private fun state(key: String, database: ClipDatabase): MobileChannelState {
        val normalized = SyncConflictResolver.normalized(database)
        return MobileChannelState(
            key = key,
            revision = "r0$key",
            plainHash = SyncRuleEngine.durablePlainHash(normalized),
            database = normalized,
            exists = true,
            salt = null
        )
    }

    private fun commit(
        transport: FakeChannelTransport,
        channels: List<MobileChannelState>,
        mutate: (ClipDatabase) -> ClipDatabase
    ): MobileChannelCommit {
        val assembly = MobileChannelEngine.buildView(channels)
        val mutated = SyncConflictResolver.normalized(mutate(assembly.view))
        return MobileChannelEngine.commit(
            transport = transport,
            document = rules,
            base = channels,
            residence = assembly.residence,
            previousMarkers = assembly.view.DeletedEntries.associateBy { comparableClipId(it.Id) },
            mutated = mutated,
            deviceName = "Android Pixel",
            now = now
        )
    }

    @Test
    fun mutationTouchingCoreOnlyUploadsCoreChannel() {
        val core = ClipDatabase(Entries = listOf(entry("a", order = 1)))
        val work = ClipDatabase(Entries = listOf(entry("b", group = "Work", order = 1)))
        val transport = FakeChannelTransport(
            mapOf("" to SyncConflictResolver.normalized(core), "work" to SyncConflictResolver.normalized(work))
        )
        val channels = listOf(state("", core), state("work", work))

        val outcome = commit(transport, channels) { view ->
            view.copy(Entries = view.Entries + entry("c", order = 99))
        }

        assertTrue(outcome.committed)
        assertEquals(listOf(""), transport.writes)
        // Core is uploaded against the revision this device already knew, so a
        // core-only mutation needs no download at all.
        assertEquals(listOf("" to "r0"), transport.writeRevisions)
        assertTrue(outcome.pending.isEmpty())
        assertEquals(setOf("a", "c"), transport.stored.getValue("").Entries.map { it.Id }.toSet())
        assertEquals(listOf("b"), transport.stored.getValue("work").Entries.map { it.Id })
    }

    @Test
    fun unchangedViewUploadsNothing() {
        val core = ClipDatabase(Entries = listOf(entry("a", order = 1)))
        val work = ClipDatabase(Entries = listOf(entry("b", group = "Work", order = 1)))
        val transport = FakeChannelTransport(
            mapOf("" to SyncConflictResolver.normalized(core), "work" to SyncConflictResolver.normalized(work))
        )
        val channels = listOf(state("", core), state("work", work))

        val outcome = commit(transport, channels) { view -> view }

        assertTrue(outcome.committed)
        assertEquals(emptyList<String>(), transport.writes)
        assertEquals(0, outcome.uploads)
    }

    @Test
    fun restoredEntryRepairsStaleRelocationMarkerThenConverges() {
        val movedAt = now - 1_000
        val staleMarker = DeletedClipEntry("restored", "", movedAt, "Desktop")
        val work = ClipDatabase(DeletedEntries = listOf(staleMarker))
        val core = ClipDatabase()
        val transport = FakeChannelTransport(
            mapOf("" to SyncConflictResolver.normalized(core), "work" to SyncConflictResolver.normalized(work))
        )
        val channels = listOf(state("", core), state("work", work))
        val restored = entry("restored", text = "Recovered text", group = "Work")

        val repaired = MobileChannelEngine.commit(
            transport = transport,
            document = rules,
            base = channels,
            residence = emptyMap(),
            previousMarkers = mapOf(comparableClipId(staleMarker.Id) to staleMarker),
            mutated = ClipDatabase(Entries = listOf(restored), DeletedEntries = listOf(staleMarker)),
            deviceName = "Android Pixel",
            now = now
        )

        assertTrue(repaired.committed)
        assertEquals(listOf("work"), transport.writes)
        assertEquals(listOf("restored"), repaired.view.Entries.map { it.Id })
        assertTrue(transport.stored.getValue("work").DeletedEntries.none { it.Id == "restored" })

        transport.writes.clear()
        val settled = commit(transport, repaired.channels) { it }
        assertTrue(settled.committed)
        assertEquals(0, settled.uploads)
        assertTrue(transport.writes.isEmpty())
    }

    @Test
    fun relocationUploadsTheTargetBeforeRewritingTheSource() {
        // The entry lives in core and a rule change moves it into work.
        val core = ClipDatabase(Entries = listOf(entry("a", order = 1), entry("m", group = "Work", order = 2)))
        val work = ClipDatabase(Entries = listOf(entry("b", group = "Work", order = 1)))
        val transport = FakeChannelTransport(
            mapOf("" to SyncConflictResolver.normalized(core), "work" to SyncConflictResolver.normalized(work))
        )
        val channels = listOf(state("", core), state("work", work))

        val outcome = commit(transport, channels) { view -> view }

        assertTrue(outcome.committed)
        val targetWrite = transport.writes.indexOf("work")
        val sourceWrite = transport.writes.lastIndexOf("")
        assertTrue("The target channel must be written", targetWrite >= 0)
        assertTrue("The source channel must be rewritten", sourceWrite >= 0)
        assertTrue(
            "The target must gain the entry before the source drops it",
            targetWrite < sourceWrite
        )

        val committedCore = transport.stored.getValue("")
        val committedWork = transport.stored.getValue("work")
        assertEquals(listOf("a"), committedCore.Entries.map { it.Id })
        assertEquals(setOf("b", "m"), committedWork.Entries.map { it.Id }.toSet())
        // The source keeps a relocation marker: an empty TextHash means "moved",
        // not "deleted", so it never suppresses the entry elsewhere.
        val marker = committedCore.DeletedEntries.first { it.Id == "m" }
        assertEquals("", marker.TextHash)
        assertEquals("Android Pixel", marker.SourceMachine)
    }

    @Test
    fun failedTargetUploadLeavesTheSourceChannelIntact() {
        val core = ClipDatabase(Entries = listOf(entry("a", order = 1), entry("m", group = "Work", order = 2)))
        val work = ClipDatabase(Entries = listOf(entry("b", group = "Work", order = 1)))
        val transport = FakeChannelTransport(
            mapOf("" to SyncConflictResolver.normalized(core), "work" to SyncConflictResolver.normalized(work))
        )
        transport.refuse = "work"
        val channels = listOf(state("", core), state("work", work))

        val outcome = commit(transport, channels) { view -> view }

        assertFalse("A refused channel upload is never reported as success", outcome.committed)
        val committedCore = transport.stored.getValue("")
        assertEquals(setOf("a", "m"), committedCore.Entries.map { it.Id }.toSet())
        assertTrue(committedCore.DeletedEntries.none { it.Id == "m" })
    }

    @Test
    fun entriesForUnsubscribedChannelsAreWrittenThroughAndParkedOnFailure() {
        // This device subscribes to work only, so a Private entry is written
        // straight through to a channel it never downloads.
        val core = ClipDatabase(Entries = listOf(entry("a", order = 1)))
        val work = ClipDatabase(Entries = listOf(entry("b", group = "Work", order = 1)))
        val delivering = FakeChannelTransport(
            mapOf("" to SyncConflictResolver.normalized(core), "work" to SyncConflictResolver.normalized(work))
        )
        val channels = listOf(state("", core), state("work", work))

        val delivered = commit(delivering, channels) { view ->
            view.copy(Entries = view.Entries + entry("p", group = "Private", order = 99))
        }

        assertTrue(delivered.committed)
        assertTrue(delivered.pending.isEmpty())
        assertEquals(listOf("private"), delivered.delivered)
        assertEquals(listOf("p"), delivering.stored.getValue("private").Entries.map { it.Id })
        assertTrue(delivering.stored.getValue("").Entries.none { it.Id == "p" })

        val refusing = FakeChannelTransport(
            mapOf("" to SyncConflictResolver.normalized(core), "work" to SyncConflictResolver.normalized(work))
        )
        refusing.refuse = "private"

        val parked = commit(refusing, channels) { view ->
            view.copy(Entries = view.Entries + entry("p", group = "Private", order = 99))
        }

        // Every subscribed channel committed, so the save itself succeeded and
        // only the undelivered entry is outstanding.
        assertTrue(parked.committed)
        assertEquals(setOf("private"), parked.pending.keys)
        assertEquals(listOf("p"), parked.pending.getValue("private").map { it.Id })
    }

    @Test
    fun crossChannelDuplicatesResolveByModifiedStampWithEarlierChannelWinningTies() {
        val older = entry("dup", text = "shared").copy(ModifiedUnixMs = now)
        val newer = entry("dup", text = "shared").copy(ModifiedUnixMs = now + 1_000)

        val coreWins = MobileChannelEngine.buildView(
            listOf(
                state("", ClipDatabase(Entries = listOf(newer))),
                state("work", ClipDatabase(Entries = listOf(older)))
            )
        )
        assertEquals("", coreWins.residence.getValue("dup"))

        val channelWins = MobileChannelEngine.buildView(
            listOf(
                state("", ClipDatabase(Entries = listOf(older))),
                state("work", ClipDatabase(Entries = listOf(newer)))
            )
        )
        assertEquals("work", channelWins.residence.getValue("dup"))

        val tie = MobileChannelEngine.buildView(
            listOf(
                state("", ClipDatabase(Entries = listOf(older))),
                state("work", ClipDatabase(Entries = listOf(older.copy(Text = "shared"))))
            )
        )
        assertEquals("", tie.residence.getValue("dup"))
        assertEquals(1, tie.view.Entries.size)
    }

    @Test
    fun channelAssemblyKeepsNewEntriesAtTheEndOfManualOrder() {
        val coreFirst = entry("core-first", order = 1).copy(CreatedUnixMs = now - 3_000)
        val coreSecond = entry("core-second", order = 2).copy(CreatedUnixMs = now - 2_000)
        val channelNew = entry("channel-new", group = "Work", order = 1).copy(CreatedUnixMs = now - 1_000)

        val assembly = MobileChannelEngine.buildView(
            listOf(
                state("", ClipDatabase(Entries = listOf(coreFirst, coreSecond))),
                state("work", ClipDatabase(Entries = listOf(channelNew)))
            )
        )

        assertEquals(listOf("core-first", "core-second", "channel-new"), assembly.view.Entries.map { it.Id })
    }

    @Test
    fun relocationMarkersNeverSuppressTheEntryTheyMoved() {
        val moved = entry("m", text = "moved text", group = "Work")
        val assembly = MobileChannelEngine.buildView(
            listOf(
                state(
                    "",
                    ClipDatabase(
                        DeletedEntries = listOf(
                            DeletedClipEntry(Id = "m", TextHash = "", DeletedUnixMs = now, SourceMachine = "Desktop")
                        )
                    )
                ),
                state("work", ClipDatabase(Entries = listOf(moved)))
            )
        )

        assertEquals(listOf("m"), assembly.view.Entries.map { it.Id })
        assertEquals("work", assembly.residence.getValue("m"))
        assertTrue(assembly.view.DeletedEntries.none { it.Id == "m" })
    }

    @Test
    fun textHashTombstonesSuppressMatchingTextInOtherChannels() {
        val deleted = entry("other-id", text = "duplicated text")
        val assembly = MobileChannelEngine.buildView(
            listOf(
                state(
                    "",
                    ClipDatabase(
                        DeletedEntries = listOf(
                            DeletedClipEntry(
                                Id = "gone",
                                TextHash = SyncConflictResolver.textHash("duplicated text"),
                                DeletedUnixMs = now + 5_000,
                                SourceMachine = "Desktop"
                            )
                        )
                    )
                ),
                state("work", ClipDatabase(Entries = listOf(deleted)))
            )
        )

        assertTrue(assembly.view.Entries.none { it.Id == "other-id" })
    }
}
