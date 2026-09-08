import Foundation

/// What the sync-rules document says about this device, as of the last transfer.
/// It is read-mostly on iOS: the settings screen shows the channels and lets the
/// user change only this device's subscription (`sync-rules-spec.md` section 5,
/// "Rules edits"); full editing stays on desktop and the CLI.
struct MobileSyncRulesSnapshot: Sendable, Equatable {
    var available = false
    var document: SyncRulesDocument? = nil
    var isReadOnly = false
    var subscribedKeys: [String] = []
    var deviceIsListed = false
    var deviceName = ""

    var isEnabled: Bool { document?.Enabled ?? false }
    var channelKeys: [String] { SyncRuleEngine.allChannelKeys(document) }

    func channelName(_ key: String) -> String {
        SyncRuleEngine.channelName(document, key: key)
    }

    /// True when this device downloads every channel, which is also what an
    /// unlisted device does.
    var subscribesToEverything: Bool {
        !deviceIsListed || subscribedKeys.count == channelKeys.count
    }
}

struct MobileSyncResult: Sendable {
    var database: ClipDatabase
    var revision: String
    var uploaded: Bool
    var backupError: String?
    /// The rules in effect after this transfer, for the settings screen.
    var rules: MobileSyncRulesSnapshot? = nil
    /// Display names of channels this device does not subscribe to that received
    /// entries by write-through (spec section 6). The UI announces these once.
    var writeThroughChannelNames: [String] = []
    /// Display names of channels whose write-through failed. Their entries are
    /// parked locally and retried after the next successful poll.
    var pendingChannelNames: [String] = []
}

struct MobileMutationError: Error, LocalizedError, Sendable {
    var localSaved: Bool
    var message: String

    var errorDescription: String? { message }
}

enum MobileSyncRulesError: Error, LocalizedError, Sendable {
    case notConfigured
    case notAvailable
    case readOnlyDocument
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Clipman Server is not configured."
        case .notAvailable:
            "Sync rules are not set up for this server yet. Use Clipman on a desktop to create them."
        case .readOnlyDocument:
            "These sync rules were written by a newer version of Clipman. Update Clipman on this device to change them."
        case .invalid(let reason):
            reason
        }
    }
}

private struct MobileChannelSyncState: Codable, Sendable {
    var key: String
    var identity: String
    var revision: String
    var plainHash: String
}

private struct MobileSyncState: Codable {
    var identity: String
    var revision: String
    var rulesIdentity: String?
    var rulesRevision: String?
    var channels: [MobileChannelSyncState]?
}

/// One sync channel as it stood at the last transfer. `key` is `""` for the core
/// channel, which keeps using the configured history bucket. `plainHash` is the
/// durable dirty-detection hash of spec section 5, upload step 4.
private struct MobileChannelState: Sendable {
    var key: String
    var identity: String
    var database: ClipDatabase
    var revision: String
    var existsOnServer: Bool
    var plainHash: String
    var salt: [UInt8]?
}

protocol MobileHistoryRepositoryProtocol: Sendable {
    func loadLocal(password: String) async throws -> ClipDatabase?
    func saveLocal(
        _ database: ClipDatabase,
        password: String,
        backupSettings: ClipmanSettings?
    ) async throws -> String?
    func synchronize(
        settings: ClipmanSettings,
        current: ClipDatabase,
        localAlreadySaved: Bool
    ) async throws -> MobileSyncResult
    func persistMutation(
        settings: ClipmanSettings,
        current: ClipDatabase,
        expectedRevision: String
    ) async throws -> MobileSyncResult
    func syncRulesSnapshot(settings: ClipmanSettings) async -> MobileSyncRulesSnapshot
    func updateDeviceSubscription(
        settings: ClipmanSettings,
        channels: [String]?
    ) async throws -> MobileSyncRulesSnapshot
}

extension MobileHistoryRepositoryProtocol {
    func syncRulesSnapshot(settings: ClipmanSettings) async -> MobileSyncRulesSnapshot {
        MobileSyncRulesSnapshot()
    }

    func updateDeviceSubscription(
        settings: ClipmanSettings,
        channels: [String]?
    ) async throws -> MobileSyncRulesSnapshot {
        throw MobileSyncRulesError.notAvailable
    }
}

actor MobileHistoryRepository: MobileHistoryRepositoryProtocol {
    static let shared = MobileHistoryRepository()

    private let fileManager = FileManager.default
    private var localEncryptedSalt: [UInt8]?

    // Sync channels (sync-rules-spec.md sections 4 to 6). With no rules document,
    // or a disabled one, all of this stays empty and every path below takes its
    // legacy branch, so behavior is identical to a client without the feature.
    private var cachedRules: SyncRulesDocument?
    private var cachedRulesLoaded = false
    private var rulesIdentity = ""
    private var rulesRevision = ""
    private var channelStates: [String: MobileChannelState] = [:]

    private static let maximumChannelConflictRetries = 3

    // MARK: - Local history

    func loadLocal(password: String) async throws -> ClipDatabase? {
        let url = try localDatabaseURL(createDirectory: false)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try ClipDatabaseFile.readBounded(from: url)
        localEncryptedSalt = ClipDatabaseFile.encryptedSalt(from: data)
        publishSharedHistorySalt()
        return try await DatabaseWorker.load(data: data, password: password)
    }

    @discardableResult
    func saveLocal(
        _ database: ClipDatabase,
        password: String,
        backupSettings: ClipmanSettings? = nil
    ) async throws -> String? {
        let data = try await DatabaseWorker.save(
            database,
            password: password,
            preferredSalt: localEncryptedSalt
        )
        return try persistEncodedLocal(data, password: password, backupSettings: backupSettings)
    }

    // MARK: - Mutations

    func persistMutation(
        settings: ClipmanSettings,
        current: ClipDatabase,
        expectedRevision: String
    ) async throws -> MobileSyncResult {
        let client = ServerStorageClient(settings: settings)
        let rules = await readRules(client: client, settings: settings)
        if let document = rules.document, document.Enabled {
            let backupError: String?
            do {
                let data = try await DatabaseWorker.save(
                    current,
                    password: settings.historyPassword,
                    preferredSalt: localEncryptedSalt
                )
                backupError = try persistEncodedLocal(
                    data,
                    password: settings.historyPassword,
                    backupSettings: settings
                )
            } catch {
                throw MobileMutationError(localSaved: false, message: error.localizedDescription)
            }
            do {
                var result = try await commitChannels(
                    settings: settings,
                    current: current,
                    client: client,
                    document: document,
                    rulesRevisionInEffect: rules.revision
                )
                result.backupError = result.backupError ?? backupError
                return result
            } catch let error as MobileMutationError {
                throw error
            } catch {
                throw MobileMutationError(localSaved: true, message: error.localizedDescription)
            }
        }
        clearChannelState()

        let previousState = loadSyncState()
        let data: Data
        let backupError: String?
        do {
            data = try await DatabaseWorker.save(
                current,
                password: settings.historyPassword,
                preferredSalt: localEncryptedSalt
            )
            backupError = try persistEncodedLocal(
                data,
                password: settings.historyPassword,
                backupSettings: settings
            )
        } catch {
            throw MobileMutationError(localSaved: false, message: error.localizedDescription)
        }

        let knownRevision: String = {
            if !expectedRevision.isEmpty { return expectedRevision }
            if previousState?.identity == client.syncCacheIdentity {
                return previousState?.revision ?? ""
            }
            return ""
        }()

        if !knownRevision.isEmpty {
            do {
                let newRevision = try await client.upload(data: data, expectedRevision: knownRevision)
                saveSyncState(identity: client.syncCacheIdentity, revision: newRevision)
                return MobileSyncResult(
                    database: current,
                    revision: newRevision,
                    uploaded: true,
                    backupError: backupError,
                    rules: rulesSnapshot(document: rules.document, settings: settings, available: client.isConfigured)
                )
            } catch ServerStorageError.conflict {
                // Another client changed the database. Fall through to a full merge.
            } catch ServerStorageError.notFound {
                // The server bucket was removed. Fall through to the normal create path.
            } catch {
                throw MobileMutationError(localSaved: true, message: error.localizedDescription)
            }
        }

        do {
            var result = try await legacySynchronize(
                settings: settings,
                current: current,
                localAlreadySaved: true
            )
            result.backupError = result.backupError ?? backupError
            result.rules = rulesSnapshot(
                document: rules.document,
                settings: settings,
                available: client.isConfigured
            )
            return result
        } catch {
            throw MobileMutationError(localSaved: true, message: error.localizedDescription)
        }
    }

    private func persistEncodedLocal(
        _ data: Data,
        password: String,
        backupSettings: ClipmanSettings?
    ) throws -> String? {
        let url = try localDatabaseURL(createDirectory: true)
        clearSyncState()
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        localEncryptedSalt = ClipDatabaseFile.encryptedSalt(from: data)
        publishSharedHistorySalt()
        guard let backupSettings, backupSettings.cloudBackupEnabled else { return nil }
        guard !password.isEmpty else {
            return "Set a nonblank history password before enabling cloud backup."
        }
        do {
            try CloudHistoryBackup.write(data, bookmark: backupSettings.cloudBackupBookmark)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Synchronization

    func synchronize(
        settings: ClipmanSettings,
        current: ClipDatabase,
        localAlreadySaved: Bool = false
    ) async throws -> MobileSyncResult {
        let client = ServerStorageClient(settings: settings)
        let rules = await readRules(client: client, settings: settings)
        guard let document = rules.document, document.Enabled else {
            clearChannelState()
            var result = try await legacySynchronize(
                settings: settings,
                current: current,
                localAlreadySaved: localAlreadySaved
            )
            result.rules = rulesSnapshot(
                document: rules.document,
                settings: settings,
                available: client.isConfigured
            )
            return result
        }
        let local: ClipDatabase
        if localAlreadySaved {
            local = current
        } else if let cached = try await loadLocal(password: settings.historyPassword) {
            local = SyncConflictResolver.merge(target: current, source: cached)
        } else {
            local = current
        }
        return try await commitChannels(
            settings: settings,
            current: local,
            client: client,
            document: document,
            rulesRevisionInEffect: rules.revision
        )
    }

    /// The single-bucket synchronization Clipman has always performed. It stays
    /// exactly as it was: with rules absent or disabled, this device behaves like
    /// a client without the feature (spec section 7).
    private func legacySynchronize(
        settings: ClipmanSettings,
        current: ClipDatabase,
        localAlreadySaved: Bool
    ) async throws -> MobileSyncResult {
        let cached: ClipDatabase?
        if localAlreadySaved {
            cached = current
        } else {
            cached = try await loadLocal(password: settings.historyPassword)
        }
        let local = if localAlreadySaved {
            current
        } else if let cached {
            SyncConflictResolver.merge(target: current, source: cached)
        } else {
            current
        }
        let client = ServerStorageClient(settings: settings)
        if localAlreadySaved,
           let state = loadSyncState(),
           state.identity == client.syncCacheIdentity,
           !state.revision.isEmpty {
            do {
                let metadata = try await client.metadata()
                if metadata.revision == state.revision {
                    return MobileSyncResult(database: local, revision: state.revision, uploaded: false, backupError: nil)
                }
            } catch ServerStorageError.notFound {
                // Continue through the normal create path below.
            } catch {
                throw error
            }
        }
        let download: ServerDatabaseDownload
        do {
            download = try await client.download()
        } catch ServerStorageError.notFound {
            let data = try await DatabaseWorker.save(
                local,
                password: settings.historyPassword,
                preferredSalt: localEncryptedSalt
            )
            let revision = try await client.upload(data: data, expectedRevision: "")
            if cached.map({ !SyncConflictResolver.hasSameContent(local, $0) }) ?? true {
                let backupError = try await saveLocal(
                    local,
                    password: settings.historyPassword,
                    backupSettings: settings
                )
                saveSyncState(identity: client.syncCacheIdentity, revision: revision)
                return MobileSyncResult(database: local, revision: revision, uploaded: true, backupError: backupError)
            }
            saveSyncState(identity: client.syncCacheIdentity, revision: revision)
            return MobileSyncResult(database: local, revision: revision, uploaded: true, backupError: nil)
        }

        let remote = try await DatabaseWorker.load(data: download.data, password: settings.historyPassword)
        let merged = SyncConflictResolver.merge(target: local, source: remote)
        let mergedMatchesRemote = SyncConflictResolver.hasSameContent(merged, remote)
        guard !mergedMatchesRemote else {
            if cached.map({ !SyncConflictResolver.hasSameContent(merged, $0) }) ?? true {
                let backupError = try await saveLocal(
                    merged,
                    password: settings.historyPassword,
                    backupSettings: settings
                )
                saveSyncState(identity: client.syncCacheIdentity, revision: download.revision)
                return MobileSyncResult(database: merged, revision: download.revision, uploaded: false, backupError: backupError)
            }
            saveSyncState(identity: client.syncCacheIdentity, revision: download.revision)
            return MobileSyncResult(database: merged, revision: download.revision, uploaded: false, backupError: nil)
        }
        let data = try await DatabaseWorker.save(
            merged,
            password: settings.historyPassword,
            preferredSalt: localEncryptedSalt
        )
        let revision = try await client.upload(data: data, expectedRevision: download.revision)
        if cached.map({ !SyncConflictResolver.hasSameContent(merged, $0) }) ?? true {
            let backupError = try await saveLocal(
                merged,
                password: settings.historyPassword,
                backupSettings: settings
            )
            saveSyncState(identity: client.syncCacheIdentity, revision: revision)
            return MobileSyncResult(database: merged, revision: revision, uploaded: true, backupError: backupError)
        }
        saveSyncState(identity: client.syncCacheIdentity, revision: revision)
        return MobileSyncResult(database: merged, revision: revision, uploaded: true, backupError: nil)
    }

    // MARK: - Channel-aware synchronization

    /// The channel-aware read and commit of spec section 5: read the rules,
    /// fetch core plus every subscribed channel, assemble one view, re-route
    /// every entry, and upload the channels whose plaintext actually changed in
    /// the add-then-remove two-phase order.
    ///
    /// A failed upload of a subscribed channel is reported as a failed save. A
    /// failed write-through to an unsubscribed channel is not: those entries are
    /// parked and retried, and everything else committed (the Committed
    /// distinction of the reference engine's WriteThroughError).
    private func commitChannels(
        settings: ClipmanSettings,
        current: ClipDatabase,
        client: ServerStorageClient,
        document: SyncRulesDocument,
        rulesRevisionInEffect: String
    ) async throws -> MobileSyncResult {
        let now = TimeUtil.nowUnixMs()
        let password = settings.historyPassword
        let deviceName = resolvedDeviceName(settings)

        // Download: core first, then every subscribed channel in document order.
        var states: [MobileChannelState] = []
        var clients: [ServerStorageClient] = []
        states.append(try await readChannel(key: SyncRuleEngine.coreChannelKey, client: client, password: password))
        clients.append(client)
        var coreSalt = states[0].salt ?? localEncryptedSalt
        for key in SyncRuleEngine.subscribedKeys(document: document, deviceName: deviceName) {
            guard let channelClient = client.addressingChannel(key, password: password) else { continue }
            states.append(try await readChannel(key: key, client: channelClient, password: password))
            clients.append(channelClient)
        }

        let subscribed = Set(states.map(\.key))
        var snapshots = states.map { SyncChannelSnapshot(key: $0.key, database: $0.database) }
        let assembled = SyncChannelAssembler.buildView(snapshots)
        let fetched = SyncChannelAssembler.fetchedEntries(snapshots)
        let previousMarkers = SyncChannelAssembler.markersByID(assembled.view.DeletedEntries)
        let view = SyncConflictResolver.merge(target: current, source: assembled.view)

        // Parked write-through entries are re-routed against the document that is
        // in effect now, not the one that was in effect when they were parked.
        let parked = loadPendingChannelWrites(password: password)
        var known = Set(view.Entries.map { SyncChannelAssembler.comparableID($0.Id) })
        var parkedEntries: [ClipEntry] = []
        for channel in parked.Channels {
            for entry in channel.Entries where known.insert(SyncChannelAssembler.comparableID(entry.Id)).inserted {
                parkedEntries.append(entry)
            }
        }

        var plan = SyncChannelAssembler.plan(
            entries: view.Entries + parkedEntries,
            document: document,
            residence: assembled.residence,
            fetched: fetched,
            subscribed: subscribed,
            deviceName: deviceName,
            now: now
        )

        // First sync: create the core bucket before anything else, so every other
        // bucket copies its salt and one PBKDF2 derivation serves them all.
        if !states[0].existsOnServer {
            let firstMarkers = SyncChannelAssembler.markers(
                channels: snapshots,
                viewMarkers: view.DeletedEntries,
                previousMarkers: previousMarkers,
                residence: assembled.residence,
                subscribed: subscribed,
                relocations: nil
            )
            let databases = SyncChannelAssembler.channelDatabases(
                channels: snapshots,
                routed: plan.withDepartures,
                markers: firstMarkers,
                now: now
            )
            var writes = !plan.pendingKeys.isEmpty
            for index in states.indices
            where SyncChannelAssembler.durableHash(databases[index]) != states[index].plainHash {
                writes = true
            }
            if writes {
                try await putChannel(
                    &states[0],
                    database: databases[0],
                    client: clients[0],
                    coreSalt: coreSalt,
                    password: password
                )
                coreSalt = states[0].salt ?? coreSalt
            }
        }

        // Write-through (spec section 6) is committed first: its targets gain
        // entries that their source channels are about to lose. When one fails
        // the entry is not taken away from where it already lives.
        var failures: [String: [ClipEntry]] = [:]
        var delivered: [String] = []
        for key in plan.pendingKeys.sorted() {
            let entries = plan.pending[key] ?? []
            guard !entries.isEmpty else { continue }
            do {
                try await writeThrough(
                    key: key,
                    entries: entries,
                    client: client,
                    coreSalt: coreSalt,
                    password: password
                )
                delivered.append(key)
            } catch {
                failures[key] = entries
                for entry in entries {
                    guard let source = assembled.residence[entry.Id] else { continue }
                    SyncChannelAssembler.cancelDeparture(&plan, entry: entry, source: source)
                }
            }
        }
        plan.withDepartures = SyncChannelAssembler.withDepartures(
            routed: plan.routed,
            departures: plan.departures,
            fetched: fetched
        )

        var uploaded = false
        var uploadFailure: Error?

        // Phase 1: every channel keeps the entries it is about to lose and
        // withholds its new relocation markers, so this pass only ever adds.
        let phaseOneMarkers = SyncChannelAssembler.markers(
            channels: snapshots,
            viewMarkers: view.DeletedEntries,
            previousMarkers: previousMarkers,
            residence: assembled.residence,
            subscribed: subscribed,
            relocations: nil
        )
        let phaseOne = SyncChannelAssembler.channelDatabases(
            channels: snapshots,
            routed: plan.withDepartures,
            markers: phaseOneMarkers,
            now: now
        )
        for index in states.indices {
            guard SyncChannelAssembler.durableHash(phaseOne[index]) != states[index].plainHash else { continue }
            do {
                try await putChannel(
                    &states[index],
                    database: phaseOne[index],
                    client: clients[index],
                    coreSalt: coreSalt,
                    password: password
                )
                uploaded = true
                if index == 0 { coreSalt = states[0].salt ?? coreSalt }
            } catch {
                uploadFailure = error
                break
            }
        }

        // Phase 2: with every addition committed, the losing channels drop their
        // departures and gain their relocation markers. A phase-2 failure is
        // safe: the entry exists in both channels and view assembly resolves the
        // duplicate until the next save repairs it.
        if uploadFailure == nil {
            snapshots = states.map { SyncChannelSnapshot(key: $0.key, database: $0.database) }
            let phaseTwoMarkers = SyncChannelAssembler.markers(
                channels: snapshots,
                viewMarkers: view.DeletedEntries,
                previousMarkers: previousMarkers,
                residence: assembled.residence,
                subscribed: subscribed,
                relocations: plan.relocations
            )
            let phaseTwo = SyncChannelAssembler.channelDatabases(
                channels: snapshots,
                routed: plan.routed,
                markers: phaseTwoMarkers,
                now: now
            )
            for index in states.indices {
                guard !(plan.departures[states[index].key] ?? []).isEmpty else { continue }
                guard SyncChannelAssembler.durableHash(phaseTwo[index]) != states[index].plainHash else { continue }
                do {
                    try await putChannel(
                        &states[index],
                        database: phaseTwo[index],
                        client: clients[index],
                        coreSalt: coreSalt,
                        password: password
                    )
                    uploaded = true
                    if index == 0 { coreSalt = states[0].salt ?? coreSalt }
                } catch {
                    uploadFailure = error
                    break
                }
            }
        }

        for state in states {
            channelStates[state.key] = state
        }
        let committedSnapshots = states.map { SyncChannelSnapshot(key: $0.key, database: $0.database) }
        let committed = SyncChannelAssembler.buildView(committedSnapshots)

        // Parked entries survive an upload failure: on a clean commit only the
        // write-throughs that failed stay parked, otherwise everything that was
        // parked before stays parked as well, because a retry is idempotent but
        // losing the only copy of an entry is not.
        var stillPending = failures
        if uploadFailure != nil {
            for channel in parked.Channels where !channel.Entries.isEmpty {
                let existing = Set((stillPending[channel.ChannelKey] ?? []).map { SyncChannelAssembler.comparableID($0.Id) })
                let extras = channel.Entries.filter { !existing.contains(SyncChannelAssembler.comparableID($0.Id)) }
                if !extras.isEmpty {
                    stillPending[channel.ChannelKey, default: []].append(contentsOf: extras)
                }
            }
        }
        savePendingChannelWrites(PendingChannelWrites.from(stillPending), password: password)

        var registered = document
        if uploadFailure == nil {
            registered = await registerDeviceIfNeeded(
                client: client,
                document: document,
                revision: rulesRevisionInEffect,
                deviceName: deviceName,
                coreSalt: coreSalt,
                password: password
            )
        }

        // A poll that changed nothing must not rewrite the local cache: encoding
        // the history costs a compression and an encryption pass every tick.
        var backupError: String?
        if uploaded || !SyncConflictResolver.hasSameContent(committed.view, current) {
            backupError = (try? await persistCommitted(
                view: committed.view,
                states: states,
                settings: settings,
                client: client
            )) ?? nil
        }

        let snapshot = rulesSnapshot(
            document: registered,
            settings: settings,
            available: client.isConfigured
        )
        if let uploadFailure {
            throw MobileMutationError(
                localSaved: true,
                message: uploadFailure.localizedDescription
            )
        }
        return MobileSyncResult(
            database: committed.view,
            revision: states[0].revision,
            uploaded: uploaded,
            backupError: backupError,
            rules: snapshot,
            writeThroughChannelNames: delivered.map { SyncRuleEngine.channelName(registered, key: $0) },
            pendingChannelNames: failures.keys.sorted().map { SyncRuleEngine.channelName(registered, key: $0) }
        )
    }

    /// Reads one channel bucket, skipping the download when its revision has not
    /// changed since the last transfer (spec section 5, download step 2). A
    /// missing bucket is an empty database, not an error.
    private func readChannel(
        key: String,
        client: ServerStorageClient,
        password: String
    ) async throws -> MobileChannelState {
        let identity = client.syncCacheIdentity
        var cached = channelStates[key]
        if cached?.identity != identity {
            cached = key.isEmpty ? nil : loadChannelCache(key: key, identity: identity, password: password)
        }
        if let cached, !cached.revision.isEmpty {
            do {
                let metadata = try await client.metadata()
                if metadata.revision == cached.revision {
                    channelStates[key] = cached
                    return cached
                }
            } catch ServerStorageError.notFound {
                // The bucket is gone; the download below turns that into an
                // empty channel and the next save recreates it.
            }
        }
        let state = try await downloadChannel(key: key, client: client, password: password, identity: identity)
        channelStates[key] = state
        return state
    }

    private func downloadChannel(
        key: String,
        client: ServerStorageClient,
        password: String,
        identity: String
    ) async throws -> MobileChannelState {
        do {
            let download = try await client.download()
            let decoded = try await DatabaseWorker.load(data: download.data, password: password)
            let normalized = SyncConflictResolver.normalized(decoded)
            return MobileChannelState(
                key: key,
                identity: identity,
                database: normalized,
                revision: download.revision,
                existsOnServer: true,
                plainHash: SyncChannelAssembler.durableHash(normalized),
                salt: ClipDatabaseFile.encryptedSalt(from: download.data)
            )
        } catch ServerStorageError.notFound {
            let empty = SyncConflictResolver.normalized(ClipDatabase())
            return MobileChannelState(
                key: key,
                identity: identity,
                database: empty,
                revision: "",
                existsOnServer: false,
                plainHash: SyncChannelAssembler.durableHash(empty),
                salt: nil
            )
        }
    }

    /// Uploads one channel with the conditional header its state calls for, and
    /// on a conflict re-reads that channel, merges the local build into the
    /// server copy and retries (spec section 5, upload step 5).
    private func putChannel(
        _ state: inout MobileChannelState,
        database: ClipDatabase,
        client: ServerStorageClient,
        coreSalt: [UInt8]?,
        password: String
    ) async throws {
        var payload = database
        var lastError: Error?
        for attempt in 0...Self.maximumChannelConflictRetries {
            let salt = state.salt ?? coreSalt
            let encoded = try await DatabaseWorker.save(payload, password: password, preferredSalt: salt)
            do {
                let revision = try await client.upload(
                    data: encoded,
                    expectedRevision: state.revision,
                    createOnly: !state.existsOnServer
                )
                state.database = payload
                state.plainHash = SyncChannelAssembler.durableHash(payload)
                state.revision = revision
                state.existsOnServer = true
                state.salt = ClipDatabaseFile.encryptedSalt(from: encoded) ?? salt
                return
            } catch ServerStorageError.conflict {
                lastError = ServerStorageError.conflict
                guard attempt < Self.maximumChannelConflictRetries else { break }
                try? await Task.sleep(nanoseconds: UInt64(30 + attempt * 40) * 1_000_000)
                let fresh = try await downloadChannel(
                    key: state.key,
                    client: client,
                    password: password,
                    identity: state.identity
                )
                payload = SyncConflictResolver.merge(target: fresh.database, source: payload)
                state.revision = fresh.revision
                state.existsOnServer = fresh.existsOnServer
                state.salt = fresh.salt ?? state.salt
            }
        }
        let name = state.key.isEmpty ? "main history" : state.key
        throw MobileMutationError(
            localSaved: true,
            message: "The \(name) changed repeatedly on Clipman Server; the change was not committed. \((lastError ?? ServerStorageError.conflict).localizedDescription)"
        )
    }

    /// The one-shot fetch-merge-put of spec section 6 for a channel this device
    /// does not subscribe to. The channel is discarded again afterwards, so its
    /// contents never reach the local view.
    private func writeThrough(
        key: String,
        entries: [ClipEntry],
        client: ServerStorageClient,
        coreSalt: [UInt8]?,
        password: String
    ) async throws {
        guard let channelClient = client.addressingChannel(key, password: password) else {
            throw MobileMutationError(
                localSaved: true,
                message: "Clipman cannot address the \(key) channel without a server token and history password."
            )
        }
        var state = try await downloadChannel(
            key: key,
            client: channelClient,
            password: password,
            identity: channelClient.syncCacheIdentity
        )
        var database = state.database
        database.DeletedEntries = SyncChannelAssembler.dropMarkers(database.DeletedEntries, forEntries: entries)
        var source = ClipDatabase()
        source.Entries = entries
        database = SyncConflictResolver.merge(target: database, source: source)
        try await putChannel(
            &state,
            database: database,
            client: channelClient,
            coreSalt: coreSalt,
            password: password
        )
    }

    // MARK: - Rules document

    /// Reads the sync-rules document (spec section 5, download step 1). It never
    /// throws: a damaged, unreachable or missing rules bucket must not stop
    /// history from syncing, and a cached document keeps working offline.
    private func readRules(
        client: ServerStorageClient,
        settings: ClipmanSettings
    ) async -> (document: SyncRulesDocument?, revision: String) {
        guard client.isConfigured,
              let rulesClient = client.addressingSyncRules(password: settings.historyPassword) else {
            return (nil, "")
        }
        let identity = rulesClient.syncCacheIdentity
        if rulesIdentity != identity {
            rulesIdentity = identity
            rulesRevision = ""
            cachedRules = nil
            cachedRulesLoaded = false
        }
        loadCachedRulesIfNeeded(password: settings.historyPassword)

        do {
            let metadata = try await rulesClient.metadata()
            if !metadata.revision.isEmpty, metadata.revision == rulesRevision, cachedRules != nil {
                return (cachedRules, rulesRevision)
            }
        } catch ServerStorageError.notFound {
            return (await restoreRulesBucket(client: rulesClient, settings: settings), "")
        } catch {
            return (cachedRules, "")
        }

        let download: ServerDatabaseDownload
        do {
            download = try await rulesClient.download()
        } catch ServerStorageError.notFound {
            return (await restoreRulesBucket(client: rulesClient, settings: settings), "")
        } catch {
            return (cachedRules, "")
        }
        guard let payload = try? ClipDatabaseFile.loadRawPayload(download.data, password: settings.historyPassword),
              let document = SyncRuleEngine.parse(payload) else {
            return (cachedRules, "")
        }
        let merged = SyncRuleEngine.merge(local: cachedRules, remote: document) ?? document
        cachedRules = merged
        storeCachedRules(merged, password: settings.historyPassword)
        // When the cache wins the last-writer-wins merge, the effective document
        // is not the one the server holds, so no revision is reported: an
        // If-Match against it would claim an edit was based on a document that
        // was never seen.
        rulesRevision = merged == document ? download.revision : ""
        return (merged, rulesRevision)
    }

    /// Restores a rules bucket that disappeared from the server, from the local
    /// cache, with `If-None-Match` so a document another device wrote in the
    /// meantime always wins (spec section 4, Caching). A cached FUTURE-VERSION
    /// document is display only and must never be re-uploaded, so it does not
    /// arm this fallback.
    private func restoreRulesBucket(
        client: ServerStorageClient,
        settings: ClipmanSettings
    ) async -> SyncRulesDocument? {
        rulesRevision = ""
        guard let cached = cachedRules else { return nil }
        guard !SyncRuleEngine.isReadOnly(cached) else { return cached }
        // Best effort: a failure leaves the cached document in effect for this
        // read and is retried on the next one.
        _ = try? await Self.uploadRules(
            cached,
            client: client,
            expectedRevision: "",
            createOnly: true,
            password: settings.historyPassword,
            salt: localEncryptedSalt
        )
        return cached
    }

    private static func uploadRules(
        _ document: SyncRulesDocument,
        client: ServerStorageClient,
        expectedRevision: String,
        createOnly: Bool,
        password: String,
        salt: [UInt8]?
    ) async throws -> String {
        guard let payload = SyncRuleEngine.serialize(document) else {
            throw MobileSyncRulesError.invalid("The sync rules could not be encoded.")
        }
        let encoded = try ClipDatabaseFile.saveRawPayload(payload, password: password, preferredSalt: salt)
        return try await client.upload(
            data: encoded,
            expectedRevision: expectedRevision,
            createOnly: createOnly
        )
    }

    /// Registry behavior of spec section 4: an updated client whose device name
    /// is missing from `Devices` adds itself with `Channels: ["*"]` on its next
    /// successful sync. Best effort; a failure is retried on the next sync.
    private func registerDeviceIfNeeded(
        client: ServerStorageClient,
        document: SyncRulesDocument,
        revision: String,
        deviceName: String,
        coreSalt: [UInt8]?,
        password: String
    ) async -> SyncRulesDocument {
        guard !SyncRuleEngine.isReadOnly(document),
              !deviceName.isEmpty,
              !SyncRuleEngine.isDeviceListed(document: document, deviceName: deviceName),
              !revision.isEmpty,
              let rulesClient = client.addressingSyncRules(password: password) else {
            return document
        }
        var updated = document
        updated.Devices.append(SyncDevice(Name: deviceName, Channels: ["*"]))
        updated.UpdatedUnixMs = TimeUtil.nowUnixMs()
        updated.UpdatedBy = deviceName
        guard SyncRuleEngine.validate(updated) == nil else { return document }
        guard let newRevision = try? await Self.uploadRules(
            updated,
            client: rulesClient,
            expectedRevision: revision,
            createOnly: false,
            password: password,
            salt: coreSalt ?? localEncryptedSalt
        ) else {
            return document
        }
        cachedRules = updated
        rulesRevision = newRevision
        storeCachedRules(updated, password: password)
        return updated
    }

    func syncRulesSnapshot(settings: ClipmanSettings) async -> MobileSyncRulesSnapshot {
        let client = ServerStorageClient(settings: settings)
        let rules = await readRules(client: client, settings: settings)
        return rulesSnapshot(
            document: rules.document,
            settings: settings,
            available: client.isConfigured
        )
    }

    /// Rewrites only this device's entry in the rules document's device registry.
    /// Everything else about the document stays desktop and CLI territory.
    func updateDeviceSubscription(
        settings: ClipmanSettings,
        channels: [String]?
    ) async throws -> MobileSyncRulesSnapshot {
        let client = ServerStorageClient(settings: settings)
        guard client.isConfigured else { throw MobileSyncRulesError.notConfigured }
        guard let rulesClient = client.addressingSyncRules(password: settings.historyPassword) else {
            throw MobileSyncRulesError.notConfigured
        }
        let deviceName = resolvedDeviceName(settings)
        guard !deviceName.isEmpty else {
            throw MobileSyncRulesError.invalid("Set a device name in Settings before choosing sync channels.")
        }

        var attempt = 0
        while true {
            let rules = await readRules(client: client, settings: settings)
            guard let document = rules.document else { throw MobileSyncRulesError.notAvailable }
            guard !SyncRuleEngine.isReadOnly(document) else { throw MobileSyncRulesError.readOnlyDocument }

            var updated = document
            let requested: [String]
            if let channels {
                let known = Set(SyncRuleEngine.allChannelKeys(document))
                requested = channels
                    .map { SyncRuleEngine.normalized($0) }
                    .filter { known.contains($0) }
            } else {
                requested = ["*"]
            }
            let target = SyncRuleEngine.normalized(deviceName)
            updated.Devices.removeAll { SyncRuleEngine.normalized($0.Name) == target }
            updated.Devices.append(SyncDevice(Name: deviceName, Channels: requested))
            updated.UpdatedUnixMs = TimeUtil.nowUnixMs()
            updated.UpdatedBy = deviceName
            if let reason = SyncRuleEngine.validate(updated) {
                throw MobileSyncRulesError.invalid(reason)
            }

            do {
                let revision = try await Self.uploadRules(
                    updated,
                    client: rulesClient,
                    expectedRevision: rules.revision,
                    createOnly: rules.revision.isEmpty,
                    password: settings.historyPassword,
                    salt: localEncryptedSalt
                )
                cachedRules = updated
                rulesRevision = revision
                storeCachedRules(updated, password: settings.historyPassword)
                // The subscription decides which channels are downloaded, so the
                // cached channel state no longer describes what is wanted.
                channelStates.removeAll()
                return rulesSnapshot(document: updated, settings: settings, available: true)
            } catch ServerStorageError.conflict {
                attempt += 1
                guard attempt <= 2 else {
                    throw MobileSyncRulesError.invalid("Another device changed the sync rules at the same time. Try again.")
                }
                rulesRevision = ""
                cachedRules = nil
                cachedRulesLoaded = true
            }
        }
    }

    private func rulesSnapshot(
        document: SyncRulesDocument?,
        settings: ClipmanSettings,
        available: Bool
    ) -> MobileSyncRulesSnapshot {
        let name = resolvedDeviceName(settings)
        let snapshot = MobileSyncRulesSnapshot(
            available: available && settings.storageMode == .server,
            document: document,
            isReadOnly: SyncRuleEngine.isReadOnly(document),
            subscribedKeys: SyncRuleEngine.subscribedKeys(document: document, deviceName: name),
            deviceIsListed: SyncRuleEngine.isDeviceListed(document: document, deviceName: name),
            deviceName: name
        )
        ShareSyncConfigurationStore.publishRules(document)
        return snapshot
    }

    private func resolvedDeviceName(_ settings: ClipmanSettings) -> String {
        settings.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func clearChannelState() {
        channelStates.removeAll()
    }

    // MARK: - Local files

    private func persistCommitted(
        view: ClipDatabase,
        states: [MobileChannelState],
        settings: ClipmanSettings,
        client: ServerStorageClient
    ) async throws -> String? {
        let data = try await DatabaseWorker.save(
            view,
            password: settings.historyPassword,
            preferredSalt: localEncryptedSalt
        )
        let backupError = try persistEncodedLocal(
            data,
            password: settings.historyPassword,
            backupSettings: settings
        )
        for state in states where !state.key.isEmpty {
            guard let encoded = try? await DatabaseWorker.save(
                state.database,
                password: settings.historyPassword,
                preferredSalt: state.salt ?? localEncryptedSalt
            ), let url = try? channelCacheURL(key: state.key, createDirectory: true) else { continue }
            try? encoded.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        }
        saveSyncState(
            identity: client.syncCacheIdentity,
            revision: states.first?.revision ?? "",
            rulesIdentity: rulesIdentity,
            rulesRevision: rulesRevision,
            channels: states.map {
                MobileChannelSyncState(
                    key: $0.key,
                    identity: $0.identity,
                    revision: $0.revision,
                    plainHash: $0.plainHash
                )
            }
        )
        return backupError
    }

    /// Seeds one channel from its local cache file so a relaunch can answer a
    /// HEAD with an unchanged revision instead of downloading the channel again.
    /// The persisted hash must match what the file decodes to, or the cache is
    /// ignored and the channel is downloaded.
    private func loadChannelCache(
        key: String,
        identity: String,
        password: String
    ) -> MobileChannelState? {
        guard let persisted = loadSyncState()?.channels?.first(where: { $0.key == key }),
              persisted.identity == identity,
              !persisted.revision.isEmpty,
              let url = try? channelCacheURL(key: key, createDirectory: false),
              fileManager.fileExists(atPath: url.path),
              let data = try? ClipDatabaseFile.readBounded(from: url),
              let decoded = try? ClipDatabaseFile.load(data, password: password) else {
            return nil
        }
        let normalized = SyncConflictResolver.normalized(decoded)
        guard SyncChannelAssembler.durableHash(normalized) == persisted.plainHash else { return nil }
        return MobileChannelState(
            key: key,
            identity: identity,
            database: normalized,
            revision: persisted.revision,
            existsOnServer: true,
            plainHash: persisted.plainHash,
            salt: ClipDatabaseFile.encryptedSalt(from: data)
        )
    }

    private func loadCachedRulesIfNeeded(password: String) {
        guard !cachedRulesLoaded else { return }
        cachedRulesLoaded = true
        guard let url = try? clipmanFileURL(named: SyncRuleEngine.syncRulesFileName, createDirectory: false),
              fileManager.fileExists(atPath: url.path),
              let data = try? ClipDatabaseFile.readBounded(from: url, maximumBytes: 1024 * 1024),
              let payload = try? ClipDatabaseFile.loadRawPayload(data, password: password) else {
            return
        }
        cachedRules = SyncRuleEngine.parse(payload)
    }

    private func storeCachedRules(_ document: SyncRulesDocument, password: String) {
        cachedRulesLoaded = true
        guard let payload = SyncRuleEngine.serialize(document),
              let encoded = try? ClipDatabaseFile.saveRawPayload(
                  payload,
                  password: password,
                  preferredSalt: localEncryptedSalt
              ),
              let url = try? clipmanFileURL(named: SyncRuleEngine.syncRulesFileName, createDirectory: true) else {
            return
        }
        try? encoded.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    private func loadPendingChannelWrites(password: String) -> PendingChannelWrites {
        guard let url = try? clipmanFileURL(named: SyncRuleEngine.pendingChannelWritesFileName, createDirectory: false),
              fileManager.fileExists(atPath: url.path),
              let data = try? ClipDatabaseFile.readBounded(from: url, maximumBytes: 8 * 1024 * 1024),
              let payload = try? ClipDatabaseFile.loadRawPayload(data, password: password),
              let decoded = try? JSONDecoder().decode(PendingChannelWrites.self, from: payload) else {
            return PendingChannelWrites()
        }
        return decoded
    }

    private func savePendingChannelWrites(_ pending: PendingChannelWrites, password: String) {
        guard let url = try? clipmanFileURL(
            named: SyncRuleEngine.pendingChannelWritesFileName,
            createDirectory: true
        ) else { return }
        guard !pending.Channels.isEmpty else {
            try? fileManager.removeItem(at: url)
            return
        }
        guard let payload = try? JSONEncoder().encode(pending),
              let encoded = try? ClipDatabaseFile.saveRawPayload(
                  payload,
                  password: password,
                  preferredSalt: localEncryptedSalt
              ) else { return }
        try? encoded.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    private func publishSharedHistorySalt() {
        guard let salt = localEncryptedSalt, salt.count == 16 else { return }
        ShareSyncConfigurationStore.publishHistorySalt(Data(salt))
    }

    private func clipmanDirectoryURL(createDirectory: Bool) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: createDirectory
        )
        let directory = base.appendingPathComponent("Clipman", isDirectory: true)
        if createDirectory {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    private func clipmanFileURL(named name: String, createDirectory: Bool) throws -> URL {
        try clipmanDirectoryURL(createDirectory: createDirectory)
            .appendingPathComponent(name, isDirectory: false)
    }

    private func localDatabaseURL(createDirectory: Bool) throws -> URL {
        try clipmanFileURL(named: "clipman-history.clipdb", createDirectory: createDirectory)
    }

    private func channelCacheURL(key: String, createDirectory: Bool) throws -> URL {
        try clipmanFileURL(
            named: SyncRuleEngine.channelFileName(key),
            createDirectory: createDirectory
        )
    }

    private func syncStateURL(createDirectory: Bool) throws -> URL {
        try clipmanFileURL(named: "server-sync-state.json", createDirectory: createDirectory)
    }

    private func loadSyncState() -> MobileSyncState? {
        guard let url = try? syncStateURL(createDirectory: false),
              let data = try? Data(contentsOf: url),
              data.count <= 262_144 else { return nil }
        return try? JSONDecoder().decode(MobileSyncState.self, from: data)
    }

    private func saveSyncState(identity: String, revision: String) {
        saveSyncState(
            identity: identity,
            revision: revision,
            rulesIdentity: nil,
            rulesRevision: nil,
            channels: nil
        )
    }

    private func saveSyncState(
        identity: String,
        revision: String,
        rulesIdentity: String?,
        rulesRevision: String?,
        channels: [MobileChannelSyncState]?
    ) {
        guard !identity.isEmpty, !revision.isEmpty,
              let data = try? JSONEncoder().encode(MobileSyncState(
                  identity: identity,
                  revision: revision,
                  rulesIdentity: rulesIdentity,
                  rulesRevision: rulesRevision,
                  channels: channels
              )),
              let url = try? syncStateURL(createDirectory: true) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    private func clearSyncState() {
        guard let url = try? syncStateURL(createDirectory: false) else { return }
        try? fileManager.removeItem(at: url)
    }
}
