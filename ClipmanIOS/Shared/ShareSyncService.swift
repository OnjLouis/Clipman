import Foundation

enum ShareSyncResult: Equatable, Sendable {
    case added
    case alreadyExists
}

enum ShareSyncError: Error, LocalizedError {
    case databaseTooLargeForExtension
    case imageHistoryDisabled
    case imageBudgetExceeded
    case repeatedConflict

    var errorDescription: String? {
        switch self {
        case .databaseTooLargeForExtension:
            "The history is too large to merge safely in the Share sheet. Open Clipman to finish adding it."
        case .imageHistoryDisabled:
            "Enable Rich Text history and Include images in Clipman before sharing a photo."
        case .imageBudgetExceeded:
            "The photo was not added because embedded images have reached Clipman's 8 MiB history limit."
        case .repeatedConflict:
            "Another device kept changing history. Open Clipman to finish adding the shared item."
        }
    }
}

/// One synchronized-history bucket the Share extension writes to. Core history and
/// every sync channel are ordinary buckets (`sync-rules-spec.md` section 2), so
/// the extension needs nothing but this to route a shared item into a channel.
protocol ShareSyncBucket {
    var databaseID: String { get }
    var createOnlyWhenMissing: Bool { get }
    func download() async throws -> ServerDatabaseDownload
    func upload(data: Data, expectedRevision: String, createOnly: Bool) async throws -> String
}

extension ServerStorageClient: ShareSyncBucket {}
extension SharedFolderStorageClient: ShareSyncBucket {}

struct ShareSyncService {
    /// The Share extension has a much smaller memory budget than the app, so it
    /// refuses to merge a blob larger than this. With sync rules in effect the
    /// limit applies to the single channel blob the shared item routes to, not to
    /// the whole history.
    static let maximumExtensionDatabaseBytes = 32 * 1024 * 1024
    private static let maximumConflictAttempts = 3

    func synchronize(text: String, html: String) async throws -> ShareSyncResult {
        let settings = try ShareSyncConfigurationStore.loadSettings()
        let richText = settings.richTextEnabled && !html.isEmpty
            ? MobileRichTextClipboard.normalize(RichTextPayload(
                HtmlFragment: html,
                PreferredFormat: "Html"
            ))
            : nil
        return try await synchronize(
            payload: MobileClipboardPayload(text: text, richText: richText, importError: nil),
            settings: settings
        )
    }

    func synchronize(imageData: Data, suggestedFilename: String?) async throws -> ShareSyncResult {
        let settings = try ShareSyncConfigurationStore.loadSettings()
        guard settings.richTextEnabled && settings.includeImagesInRichText else {
            throw ShareSyncError.imageHistoryDisabled
        }
        let payload = try await Task.detached(priority: .userInitiated) {
            try EmbeddedImageCodec.makePayload(
                data: imageData,
                suggestedFilename: suggestedFilename
            )
        }.value
        return try await synchronize(payload: payload, settings: settings)
    }

    private func synchronize(
        payload: MobileClipboardPayload,
        settings: ShareSyncSettings
    ) async throws -> ShareSyncResult {
        try await synchronize(
            payload: payload,
            settings: settings,
            rules: ShareSyncConfigurationStore.loadRules()
        ) { channelKey in
            try Self.storageBucket(channelKey: channelKey, settings: settings)
        }
    }

    /// Routes the shared item with the cached rules document and writes it to the
    /// bucket of the channel it belongs in, with the same conflict retry loop the
    /// extension has always used. `resolveBucket` receives the normalized channel
    /// key, `""` meaning the core history.
    func synchronize(
        payload: MobileClipboardPayload,
        settings: ShareSyncSettings,
        rules: SyncRulesDocument?,
        resolveBucket: (String) throws -> any ShareSyncBucket
    ) async throws -> ShareSyncResult {
        let text = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw PendingSharedTextError.emptyText }

        let channelKey = Self.targetChannelKey(payload: payload, settings: settings, rules: rules)
        let bucket = try resolveBucket(channelKey)
        let createsChannel = !channelKey.isEmpty

        for _ in 0..<Self.maximumConflictAttempts {
            let remoteData: Data?
            let revision: String
            do {
                let download = try await bucket.download()
                remoteData = download.data
                revision = download.revision
            } catch ServerStorageError.notFound {
                remoteData = nil
                revision = ""
            } catch ServerStorageError.responseTooLarge {
                throw ShareSyncError.databaseTooLargeForExtension
            }

            let remote: ClipDatabase
            if let remoteData {
                remote = try await DatabaseWorker.load(
                    data: remoteData,
                    password: settings.historyPassword
                )
            } else {
                remote = ClipDatabase()
            }

            let mutation = try ShareSyncDatabaseMutation.applying(
                payload: payload,
                to: remote,
                settings: settings
            )
            // A channel blob created for the first time copies the core
            // database's salt, so one PBKDF2 derivation serves every bucket.
            let encoded = try await DatabaseWorker.save(
                mutation.database,
                password: settings.historyPassword,
                preferredSalt: remoteData.flatMap(ClipDatabaseFile.encryptedSalt)
                    ?? ShareSyncConfigurationStore.loadHistorySalt()
            )
            do {
                _ = try await bucket.upload(
                    data: encoded,
                    expectedRevision: revision,
                    createOnly: (createsChannel || bucket.createOnlyWhenMissing) && revision.isEmpty
                )
                return mutation.alreadyExists ? .alreadyExists : .added
            } catch ServerStorageError.conflict {
                continue
            } catch ServerStorageError.responseTooLarge {
                throw ShareSyncError.databaseTooLargeForExtension
            }
        }
        throw ShareSyncError.repeatedConflict
    }

    /// The channel a shared item routes to, computed from the same fields every
    /// other client routes on (spec section 4). Shared items carry no group, so
    /// only `SourceDevices` and `RichTextImages` routes can match them.
    static func targetChannelKey(
        payload: MobileClipboardPayload,
        settings: ShareSyncSettings,
        rules: SyncRulesDocument?
    ) -> String {
        SyncRuleEngine.route(
            document: rules,
            entry: ClipEntry(
                Text: payload.text.trimmingCharacters(in: .whitespacesAndNewlines),
                SourceMachine: settings.deviceName,
                RichText: settings.richTextEnabled ? payload.richText : nil
            )
        )
    }

    static func serverBucket(channelKey: String, settings: ShareSyncSettings) throws -> any ShareSyncBucket {
        let client = ServerStorageClient(
            settings: settings,
            maximumResponseBytes: maximumExtensionDatabaseBytes
        )
        guard client.isConfigured else { throw ShareSyncConfigurationError.invalidConfiguration }
        guard !channelKey.isEmpty else { return client }
        guard let channel = client.addressingChannel(channelKey, password: settings.historyPassword) else {
            throw ShareSyncConfigurationError.invalidConfiguration
        }
        return channel
    }

    static func storageBucket(channelKey: String, settings: ShareSyncSettings) throws -> any ShareSyncBucket {
        guard settings.storageMode == "sharedFolder" else {
            return try serverBucket(channelKey: channelKey, settings: settings)
        }
        let client = SharedFolderStorageClient(
            bookmark: settings.sharedFolderBookmark,
            password: settings.historyPassword
        )
        guard client.isConfigured else { throw ShareSyncConfigurationError.invalidConfiguration }
        guard !channelKey.isEmpty else { return client }
        guard let channel = client.historyChannel(channelKey, password: settings.historyPassword) as? SharedFolderStorageClient else {
            throw ShareSyncConfigurationError.invalidConfiguration
        }
        return channel
    }
}

extension ShareSyncBucket {
    var createOnlyWhenMissing: Bool { false }
}

enum ShareSyncDatabaseMutation {
    static func applying(
        payload: MobileClipboardPayload,
        to database: ClipDatabase,
        settings: ShareSyncSettings
    ) throws -> (database: ClipDatabase, alreadyExists: Bool) {
        let text = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw PendingSharedTextError.emptyText }
        if let image = payload.embeddedImage {
            let existingBytes = database.Entries.first(where: { $0.Text == text })
                .flatMap { EmbeddedImageCodec.recognize($0.RichText)?.data.count } ?? 0
            let projectedBytes = EmbeddedImageCodec.totalStoredBytes(in: database)
                - existingBytes
                + image.data.count
            guard projectedBytes <= EmbeddedImageCodec.totalDatabaseBudget else {
                throw ShareSyncError.imageBudgetExceeded
            }
        }
        return (
            SyncConflictResolver.addText(
                database: database,
                text: text,
                machineName: settings.deviceName,
                richText: settings.richTextEnabled ? payload.richText : nil
            ),
            database.Entries.contains { $0.Text == text }
        )
    }
}
