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

struct ShareSyncService {
    private static let maximumExtensionDatabaseBytes = 32 * 1024 * 1024
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
        let text = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw PendingSharedTextError.emptyText }

        let client = ServerStorageClient(
            settings: settings,
            maximumResponseBytes: Self.maximumExtensionDatabaseBytes
        )
        guard client.isConfigured else { throw ShareSyncConfigurationError.invalidConfiguration }

        for _ in 0..<Self.maximumConflictAttempts {
            let remoteData: Data?
            let revision: String
            do {
                let download = try await client.download()
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
            let encoded = try await DatabaseWorker.save(
                mutation.database,
                password: settings.historyPassword,
                preferredSalt: remoteData.flatMap(ClipDatabaseFile.encryptedSalt)
            )
            do {
                _ = try await client.upload(data: encoded, expectedRevision: revision)
                return mutation.alreadyExists ? .alreadyExists : .added
            } catch ServerStorageError.conflict {
                continue
            } catch ServerStorageError.responseTooLarge {
                throw ShareSyncError.databaseTooLargeForExtension
            }
        }
        throw ShareSyncError.repeatedConflict
    }
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
