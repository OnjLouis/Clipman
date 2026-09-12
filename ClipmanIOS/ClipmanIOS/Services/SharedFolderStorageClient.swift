import CryptoKit
import Foundation

enum SharedFolderStorageError: Error, LocalizedError {
    case unavailable
    case staleBookmark
    case invalidPassword
    case invalidRules

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "The selected shared folder is unavailable. Clipman will keep the change locally and retry."
        case .staleBookmark:
            "Permission for the shared folder has expired. Choose the folder again in Settings."
        case .invalidPassword:
            "Shared folder sync requires a nonblank history password."
        case .invalidRules:
            "The shared sync-rules file could not be decoded."
        }
    }
}

/// Presents a coordinated file as the same revisioned storage contract used by
/// Clipman Server. The repository therefore applies one merge algorithm to both
/// transports, including deletion tombstones and channel routing.
final class SharedFolderStorageClient: @unchecked Sendable, HistoryStorageClient {
    enum ContentKind: Sendable {
        case history
        case rules
    }

    let isConfigured: Bool
    let syncCacheIdentity: String
    let databaseID: String
    let storageName = "shared folder"
    let createOnlyWhenMissing = true

    private let bookmark: Data?
    private let directDirectory: URL?
    private let password: String
    private let fileName: String
    private let contentKind: ContentKind

    init(bookmark: Data, password: String) {
        self.bookmark = bookmark
        self.directDirectory = nil
        self.password = password
        self.fileName = "clipman-history.clipdb"
        self.contentKind = .history
        self.databaseID = fileName
        self.isConfigured = !bookmark.isEmpty && !password.isEmpty
        self.syncCacheIdentity = "shared-folder|\(Self.bookmarkIdentity(bookmark))|\(fileName)"
    }

    init(directory: URL, password: String, fileName: String = "clipman-history.clipdb", contentKind: ContentKind = .history) {
        self.bookmark = nil
        self.directDirectory = directory
        self.password = password
        self.fileName = fileName
        self.contentKind = contentKind
        self.databaseID = fileName
        self.isConfigured = !password.isEmpty
        self.syncCacheIdentity = "shared-folder|\(directory.standardizedFileURL.path)|\(fileName)"
    }

    private init(parent: SharedFolderStorageClient, fileName: String, contentKind: ContentKind) {
        self.bookmark = parent.bookmark
        self.directDirectory = parent.directDirectory
        self.password = parent.password
        self.fileName = fileName
        self.contentKind = contentKind
        self.databaseID = fileName
        self.isConfigured = parent.isConfigured
        self.syncCacheIdentity = "\(parent.syncCacheIdentity.components(separatedBy: "|").dropLast().joined(separator: "|"))|\(fileName)"
    }

    func historyChannel(_ channelKey: String, password: String) -> (any HistoryStorageClient)? {
        guard isConfigured, self.password == password else { return nil }
        return SharedFolderStorageClient(
            parent: self,
            fileName: SyncRuleEngine.channelFileName(channelKey),
            contentKind: .history
        )
    }

    func historySyncRules(password: String) -> (any HistoryStorageClient)? {
        guard isConfigured, self.password == password else { return nil }
        return SharedFolderStorageClient(
            parent: self,
            fileName: SyncRuleEngine.syncRulesFileName,
            contentKind: .rules
        )
    }

    func metadata() async throws -> ServerDatabaseMetadata {
        let candidates = try readCandidates()
        guard !candidates.isEmpty else { throw ServerStorageError.notFound }
        return ServerDatabaseMetadata(revision: Self.revision(for: candidates))
    }

    func download() async throws -> ServerDatabaseDownload {
        let candidates = try readCandidates()
        guard let first = candidates.first else { throw ServerStorageError.notFound }
        let revision = Self.revision(for: candidates)
        guard candidates.count > 1 else {
            return ServerDatabaseDownload(revision: revision, data: first.data)
        }

        let merged = try await merge(candidates.map(\.data))
        return ServerDatabaseDownload(revision: revision, data: merged)
    }

    func upload(data: Data, expectedRevision: String, createOnly: Bool = false) async throws -> String {
        guard isConfigured else {
            throw password.isEmpty ? SharedFolderStorageError.invalidPassword : SharedFolderStorageError.unavailable
        }
        guard data.count <= ClipDatabaseFile.maximumFileBytes else { throw ServerStorageError.responseTooLarge }
        return try withDirectory { directory in
            let target = directory.appendingPathComponent(fileName, isDirectory: false)
            var coordinationError: NSError?
            var result: Result<String, Error>!
            var didWrite = false
            NSFileCoordinator().coordinate(writingItemAt: target, options: [], error: &coordinationError) { coordinatedURL in
                do {
                    let candidates = try Self.readCandidates(canonical: coordinatedURL)
                    if createOnly && !candidates.isEmpty { throw ServerStorageError.conflict }
                    if !expectedRevision.isEmpty,
                       Self.revision(for: candidates) != expectedRevision {
                        throw ServerStorageError.conflict
                    }
                    try data.write(to: coordinatedURL, options: [.atomic, .completeFileProtectionUnlessOpen])
                    didWrite = true
                    result = .success(Self.revision(for: [Candidate(url: coordinatedURL, data: data)]))
                } catch {
                    result = .failure(error)
                }
            }
            if let coordinationError { throw coordinationError }
            if didWrite { Self.resolveConflicts(canonical: target) }
            return try result.get()
        }
    }

    private func readCandidates() throws -> [Candidate] {
        guard isConfigured else {
            throw password.isEmpty ? SharedFolderStorageError.invalidPassword : SharedFolderStorageError.unavailable
        }
        return try withDirectory { directory in
            let target = directory.appendingPathComponent(fileName, isDirectory: false)
            var coordinationError: NSError?
            var result: Result<[Candidate], Error>!
            NSFileCoordinator().coordinate(readingItemAt: target, options: .withoutChanges, error: &coordinationError) { coordinatedURL in
                do {
                    result = .success(try Self.readCandidates(canonical: coordinatedURL))
                } catch {
                    result = .failure(error)
                }
            }
            if let coordinationError { throw coordinationError }
            return try result.get()
        }
    }

    private func merge(_ payloads: [Data]) async throws -> Data {
        let password = password
        let kind = contentKind
        return try await Task.detached(priority: .userInitiated) {
            switch kind {
            case .history:
                var merged = ClipDatabase()
                for data in payloads {
                    merged = SyncConflictResolver.merge(
                        target: merged,
                        source: try ClipDatabaseFile.load(data, password: password)
                    )
                }
                return try ClipDatabaseFile.save(
                    merged,
                    password: password,
                    preferredSalt: payloads.compactMap(ClipDatabaseFile.encryptedSalt).first
                )
            case .rules:
                var merged: SyncRulesDocument?
                for data in payloads {
                    let raw = try ClipDatabaseFile.loadRawPayload(data, password: password)
                    guard let document = SyncRuleEngine.parse(raw) else { continue }
                    merged = SyncRuleEngine.merge(local: merged, remote: document) ?? document
                }
                guard let merged, let raw = SyncRuleEngine.serialize(merged) else {
                    throw SharedFolderStorageError.invalidRules
                }
                return try ClipDatabaseFile.saveRawPayload(
                    raw,
                    password: password,
                    preferredSalt: payloads.compactMap(ClipDatabaseFile.encryptedSalt).first
                )
            }
        }.value
    }

    private func withDirectory<T>(_ body: (URL) throws -> T) throws -> T {
        let directory: URL
        if let directDirectory {
            directory = directDirectory
        } else if let bookmark {
            var stale = false
            directory = try URL(
                resolvingBookmarkData: bookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            guard !stale else { throw SharedFolderStorageError.staleBookmark }
        } else {
            throw SharedFolderStorageError.unavailable
        }
        let scoped = directDirectory == nil && directory.startAccessingSecurityScopedResource()
        guard directDirectory != nil || scoped else { throw SharedFolderStorageError.unavailable }
        defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try body(directory)
    }

    private struct Candidate {
        var url: URL
        var data: Data
    }

    private static func readCandidates(canonical: URL) throws -> [Candidate] {
        var urls: [URL] = []
        if FileManager.default.fileExists(atPath: canonical.path) { urls.append(canonical) }
        urls.append(contentsOf: conflictSiblings(for: canonical))
        urls.append(contentsOf: (NSFileVersion.unresolvedConflictVersionsOfItem(at: canonical) ?? []).compactMap(\.url))

        var seen = Set<String>()
        var result: [Candidate] = []
        for url in urls where seen.insert(url.standardizedFileURL.path).inserted {
            do {
                if (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true {
                    try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                }
                let data = try ClipDatabaseFile.readBounded(from: url)
                result.append(Candidate(url: url, data: data))
            } catch ClipDatabaseError.databaseFileTooLarge {
                throw ServerStorageError.responseTooLarge
            } catch {
                // A cloud placeholder can exist before its bytes are available.
                // Treat that as unavailable rather than missing so a local create
                // can never replace an unhydrated history or conflict version.
                throw error
            }
        }
        return result
    }

    private static func revision(for candidates: [Candidate]) -> String {
        let hashes = candidates.map { SHA256.hash(data: $0.data).map { String(format: "%02x", $0) }.joined() }.sorted()
        let digest = SHA256.hash(data: Data(hashes.joined(separator: "|").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func resolveConflicts(canonical: URL) {
        for sibling in conflictSiblings(for: canonical) {
            try? FileManager.default.removeItem(at: sibling)
        }
        for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: canonical) ?? [] {
            version.isResolved = true
        }
        try? NSFileVersion.removeOtherVersionsOfItem(at: canonical)
    }

    private static func conflictSiblings(for canonical: URL) -> [URL] {
        let directory = canonical.deletingLastPathComponent()
        let base = canonical.deletingPathExtension().lastPathComponent
        let ext = canonical.pathExtension
        guard let children = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return children.filter { url in
            guard url != canonical,
                  url.pathExtension.caseInsensitiveCompare(ext) == .orderedSame else { return false }
            let name = url.deletingPathExtension().lastPathComponent
            guard name.range(of: base, options: [.caseInsensitive, .anchored]) != nil else { return false }
            let suffix = name.dropFirst(base.count).lowercased()
            if suffix.contains("conflicted copy") || suffix.contains("[conflict]") || suffix.contains(" conflict") {
                return true
            }
            if suffix.hasPrefix("_conf(") || suffix.hasPrefix(" _conf(") { return true }
            return looksLikeProviderComputerSuffix(String(name.dropFirst(base.count)))
        }
    }

    private static func looksLikeProviderComputerSuffix(_ suffix: String) -> Bool {
        var value = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 3 && value.count <= 80 else { return false }
        guard value.hasPrefix("-") || value.hasPrefix("(") || value.hasPrefix(" ") else { return false }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: " -()"))
        guard value.count >= 2 && value.count <= 64 else { return false }
        return value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    private static func bookmarkIdentity(_ bookmark: Data) -> String {
        SHA256.hash(data: bookmark).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
