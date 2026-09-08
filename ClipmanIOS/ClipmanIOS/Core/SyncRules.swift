import CryptoKit
import Foundation

// MARK: - Document model

/// The sync-rules document of `sync-rules-spec.md` section 4: named channels,
/// the routes that fill them, and per-device subscriptions. It lives in its own
/// bucket, never inside the history database, because other Clipman clients drop
/// unknown JSON fields when they save a `ClipDatabase`.
struct SyncRulesDocument: Codable, Equatable, Sendable {
    var Clipman: String
    var Version: Int
    var Enabled: Bool
    var UpdatedUnixMs: Int64
    var UpdatedBy: String
    var Channels: [SyncChannel]
    var Devices: [SyncDevice]

    init(
        Clipman: String = SyncRuleEngine.documentKind,
        Version: Int = SyncRuleEngine.currentVersion,
        Enabled: Bool = false,
        UpdatedUnixMs: Int64 = 0,
        UpdatedBy: String = "",
        Channels: [SyncChannel] = [],
        Devices: [SyncDevice] = []
    ) {
        self.Clipman = Clipman
        self.Version = Version
        self.Enabled = Enabled
        self.UpdatedUnixMs = UpdatedUnixMs
        self.UpdatedBy = UpdatedBy
        self.Channels = Channels
        self.Devices = Devices
    }

    private enum CodingKeys: String, CodingKey {
        case Clipman, Version, Enabled, UpdatedUnixMs, UpdatedBy, Channels, Devices
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        Clipman = try values.decodeIfPresent(String.self, forKey: .Clipman) ?? ""
        Version = try values.decodeIfPresent(Int.self, forKey: .Version) ?? SyncRuleEngine.currentVersion
        Enabled = try values.decodeIfPresent(Bool.self, forKey: .Enabled) ?? false
        UpdatedUnixMs = try values.decodeIfPresent(Int64.self, forKey: .UpdatedUnixMs) ?? 0
        UpdatedBy = try values.decodeIfPresent(String.self, forKey: .UpdatedBy) ?? ""
        Channels = try values.decodeIfPresent([SyncChannel].self, forKey: .Channels) ?? []
        Devices = try values.decodeIfPresent([SyncDevice].self, forKey: .Devices) ?? []
    }
}

/// One named partition of history together with the route that fills it.
struct SyncChannel: Codable, Equatable, Sendable {
    var Name: String
    var Route: SyncRoute

    init(Name: String = "", Route: SyncRoute = SyncRoute()) {
        self.Name = Name
        self.Route = Route
    }

    private enum CodingKeys: String, CodingKey {
        case Name, Route
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        Name = try values.decodeIfPresent(String.self, forKey: .Name) ?? ""
        Route = try values.decodeIfPresent(SyncRoute.self, forKey: .Route) ?? SyncRoute()
    }
}

/// The conditions, ANDed together, that route an entry into its channel. A route
/// with no condition set never matches; `SyncRuleEngine.validate` rejects such
/// routes, but routing stays safe against an unvalidated future document.
struct SyncRoute: Codable, Equatable, Sendable {
    var Groups: [String]?
    var SourceDevices: [String]?
    var Kind: String?

    init(Groups: [String]? = nil, SourceDevices: [String]? = nil, Kind: String? = nil) {
        self.Groups = Groups
        self.SourceDevices = SourceDevices
        self.Kind = Kind
    }

    private enum CodingKeys: String, CodingKey {
        case Groups, SourceDevices, Kind
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        Groups = try values.decodeIfPresent([String].self, forKey: .Groups)
        SourceDevices = try values.decodeIfPresent([String].self, forKey: .SourceDevices)
        Kind = try values.decodeIfPresent(String.self, forKey: .Kind)
    }

    /// Mirrors the reference implementation's `omitempty`: absent, empty and
    /// blank conditions are not written back out.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let groups = Groups, !groups.isEmpty {
            try container.encode(groups, forKey: .Groups)
        }
        if let sourceDevices = SourceDevices, !sourceDevices.isEmpty {
            try container.encode(sourceDevices, forKey: .SourceDevices)
        }
        if let kind = Kind, !kind.isEmpty {
            try container.encode(kind, forKey: .Kind)
        }
    }
}

/// The channels one named device downloads. Core is implicit and always synced.
struct SyncDevice: Codable, Equatable, Sendable {
    var Name: String
    var Channels: [String]

    init(Name: String = "", Channels: [String] = []) {
        self.Name = Name
        self.Channels = Channels
    }

    private enum CodingKeys: String, CodingKey {
        case Name, Channels
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        Name = try values.decodeIfPresent(String.self, forKey: .Name) ?? ""
        Channels = try values.decodeIfPresent([String].self, forKey: .Channels) ?? []
    }
}

/// Entries captured on this device that route to a channel it does not subscribe
/// to and whose write-through failed (`sync-rules-spec.md` section 6). They are
/// kept beside the local history cache and retried after the next successful
/// poll; they never appear in the local view.
struct PendingChannelWrites: Codable, Equatable, Sendable {
    var Channels: [PendingChannelWrite]

    init(Channels: [PendingChannelWrite] = []) {
        self.Channels = Channels
    }

    private enum CodingKeys: String, CodingKey {
        case Channels
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        Channels = try values.decodeIfPresent([PendingChannelWrite].self, forKey: .Channels) ?? []
    }

    /// The parked entries as a channel-key keyed map, in stored order.
    var byChannelKey: [String: [ClipEntry]] {
        var result: [String: [ClipEntry]] = [:]
        for channel in Channels where !channel.Entries.isEmpty {
            result[channel.ChannelKey, default: []].append(contentsOf: channel.Entries)
        }
        return result
    }

    /// Builds a store payload from a channel-key keyed map, dropping empties and
    /// ordering the channels so the file is stable between writes.
    static func from(_ entries: [String: [ClipEntry]]) -> PendingChannelWrites {
        PendingChannelWrites(
            Channels: entries.keys.sorted().compactMap { key in
                guard let value = entries[key], !value.isEmpty else { return nil }
                return PendingChannelWrite(ChannelKey: key, Entries: value)
            }
        )
    }
}

struct PendingChannelWrite: Codable, Equatable, Sendable {
    var ChannelKey: String
    var Entries: [ClipEntry]

    init(ChannelKey: String = "", Entries: [ClipEntry] = []) {
        self.ChannelKey = ChannelKey
        self.Entries = Entries
    }

    private enum CodingKeys: String, CodingKey {
        case ChannelKey, Entries
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        ChannelKey = try values.decodeIfPresent(String.self, forKey: .ChannelKey) ?? ""
        Entries = try values.decodeIfPresent([ClipEntry].self, forKey: .Entries) ?? []
    }
}

// MARK: - Rule engine

/// Channel key derivation, document validation, per-entry routing, device
/// subscriptions and whole-document last-writer-wins merge, exactly as
/// `sync-rules-spec.md` sections 3 and 4 require. Every Clipman client must
/// produce the same answers here, or the same entry would land in different
/// channels on different devices.
enum SyncRuleEngine {
    static let documentKind = "sync-rules"
    static let currentVersion = 1
    static let richTextImagesKind = "RichTextImages"
    /// The core channel, which keeps using the existing history bucket and file.
    static let coreChannelKey = ""
    static let syncRulesFileName = "clipman-sync-rules.clipdb"
    static let pendingChannelWritesFileName = "clipman-pending-channels.clipdb"

    private static let dataImagePrefix = "data:image/"
    private static let reservedChannelKeys: Set<String> = ["core", "all", "pinned", "sync-rules"]

    /// The `lowerInvariant(trim(x))` comparison rule used throughout spec
    /// section 3 for channel keys, device names and groups. `lowercased()` is
    /// Unicode-aware but locale independent, and channel keys are ASCII-only by
    /// grammar, so it is an adequate invariant lowering here.
    static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The channel key for a display name: `lowerInvariant(trim(Name))` when it
    /// matches `[a-z0-9]([a-z0-9 _-]{0,30}[a-z0-9])?` and is pure ASCII, and
    /// `""` (meaning "not a usable channel") otherwise.
    static func channelKey(_ name: String) -> String {
        let key = normalized(name)
        return matchesChannelKeyGrammar(key) ? key : ""
    }

    /// The local cache file name for one channel, mirroring the shared-folder
    /// sibling names of spec section 2.
    static func channelFileName(_ key: String) -> String {
        "clipman-channel-" + key.replacingOccurrences(of: " ", with: "-") + ".clipdb"
    }

    /// A document written by a future format version is applied where it is
    /// understood but never rewritten by this client (spec section 4, Version).
    static func isReadOnly(_ document: SyncRulesDocument?) -> Bool {
        guard let document else { return false }
        return document.Version > currentVersion
    }

    /// Whether a document read from storage may be applied. A future-version
    /// document is accepted leniently - a client must never fail entirely on a
    /// document it only partly understands - while a current-version document
    /// must still pass strict validation, since editors validate before writing.
    static func isUsable(_ document: SyncRulesDocument?) -> Bool {
        guard let document, document.Clipman == documentKind else { return false }
        if isReadOnly(document) { return true }
        return validate(document) == nil
    }

    /// Returns nil when the document is valid, or a display-ready reason.
    static func validate(_ document: SyncRulesDocument?) -> String? {
        guard let document else { return "The sync rules document is missing." }
        guard document.Clipman == documentKind else {
            return "The sync rules document has an unrecognized format."
        }

        var knownKeys = Set<String>()
        for channel in document.Channels {
            let key = channelKey(channel.Name)
            guard !key.isEmpty else {
                return "Channel name \"\(channel.Name)\" is not valid. Use 1 to 32 letters, digits, spaces, dashes or underscores, starting and ending with a letter or digit."
            }
            guard !reservedChannelKeys.contains(key) else {
                return "Channel name \"\(channel.Name)\" is reserved."
            }
            guard knownKeys.insert(key).inserted else {
                return "Channel name \"\(channel.Name)\" is not unique."
            }

            let route = channel.Route
            let hasGroups = !(route.Groups ?? []).isEmpty
            let hasSourceDevices = !(route.SourceDevices ?? []).isEmpty
            let kind = route.Kind ?? ""
            guard hasGroups || hasSourceDevices || !kind.isEmpty else {
                return "Channel \"\(channel.Name)\" has no routing condition."
            }
            guard kind.isEmpty || kind == richTextImagesKind else {
                return "Channel \"\(channel.Name)\" has an unrecognized route kind."
            }
        }

        for device in document.Devices {
            if device.Channels.contains(where: { isWildcard($0) }) {
                guard device.Channels.count == 1 else {
                    return "Device \"\(device.Name)\" mixes all channels with named channels."
                }
                continue
            }
            for reference in device.Channels where !knownKeys.contains(normalized(reference)) {
                return "Device \"\(device.Name)\" references unknown channel \"\(reference)\"."
            }
        }

        return nil
    }

    /// The key of the first channel, in document order, whose route matches the
    /// entry, or `""` when the document is missing, disabled, or nothing matches
    /// - meaning the entry lives in core.
    ///
    /// A matching channel whose name yields no valid key resolves to `""` as
    /// well, exactly as the reference implementation does: such a channel can
    /// only come from a future-version document, and stopping there keeps the
    /// entry in core rather than filing it under a later, unrelated rule.
    static func route(document: SyncRulesDocument?, entry: ClipEntry?) -> String {
        guard let document, document.Enabled, let entry else { return coreChannelKey }
        for channel in document.Channels where routeMatches(channel.Route, entry) {
            return channelKey(channel.Name)
        }
        return coreChannelKey
    }

    /// The channel keys the named device downloads besides core, in document
    /// order. Returns nil when the document is missing, disabled, or the device
    /// is not listed - nil means "subscribe to everything" (spec section 4).
    static func subscribedChannels(document: SyncRulesDocument?, deviceName: String) -> [String]? {
        guard let document, document.Enabled else { return nil }

        let target = normalized(deviceName)
        guard let device = document.Devices.first(where: { normalized($0.Name) == target }) else {
            return nil
        }
        if device.Channels.contains(where: { isWildcard($0) }) {
            return allChannelKeys(document)
        }

        let known = Set(allChannelKeys(document))
        var subscribed: [String] = []
        for reference in device.Channels {
            let key = normalized(reference)
            if known.contains(key), !subscribed.contains(key) {
                subscribed.append(key)
            }
        }
        return subscribed
    }

    /// Every usable channel key in document order, deduplicated.
    static func allChannelKeys(_ document: SyncRulesDocument?) -> [String] {
        guard let document else { return [] }
        var keys: [String] = []
        for channel in document.Channels {
            let key = channelKey(channel.Name)
            if !key.isEmpty, !keys.contains(key) {
                keys.append(key)
            }
        }
        return keys
    }

    /// The display name recorded for a channel key, falling back to the key.
    static func channelName(_ document: SyncRulesDocument?, key: String) -> String {
        guard !key.isEmpty else { return "the main history" }
        guard let document else { return key }
        for channel in document.Channels where channelKey(channel.Name) == key {
            return channel.Name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return key
    }

    /// The channel keys the named device downloads, resolved against the
    /// document's own channel order. An unlisted device subscribes to all of
    /// them; keys the document does not define are dropped.
    static func subscribedKeys(document: SyncRulesDocument?, deviceName: String) -> [String] {
        guard let document, document.Enabled else { return [] }
        guard let subscribed = subscribedChannels(document: document, deviceName: deviceName) else {
            return allChannelKeys(document)
        }
        let wanted = Set(subscribed)
        return allChannelKeys(document).filter { wanted.contains($0) }
    }

    /// Whether the named device appears in the document's device registry.
    static func isDeviceListed(document: SyncRulesDocument?, deviceName: String) -> Bool {
        guard let document else { return false }
        let target = normalized(deviceName)
        return document.Devices.contains { normalized($0.Name) == target }
    }

    /// Whole-document last-writer-wins on `UpdatedUnixMs`, breaking ties toward
    /// the greater `UpdatedBy` by ordinal comparison. A nil document loses to a
    /// non-nil one; two nil documents merge to nil.
    static func merge(local: SyncRulesDocument?, remote: SyncRulesDocument?) -> SyncRulesDocument? {
        guard let local else { return remote }
        guard let remote else { return local }
        if remote.UpdatedUnixMs > local.UpdatedUnixMs { return remote }
        if remote.UpdatedUnixMs < local.UpdatedUnixMs { return local }
        return ordinalCompare(remote.UpdatedBy, local.UpdatedBy) > 0 ? remote : local
    }

    /// Decodes a rules document, rejecting any payload whose `Clipman` field is
    /// not `sync-rules`. A future-version document skips strict validation so a
    /// client never fails entirely on a document it only partly understands.
    static func parse(_ data: Data) -> SyncRulesDocument? {
        guard let document = try? JSONDecoder().decode(SyncRulesDocument.self, from: data) else {
            return nil
        }
        guard document.Clipman == documentKind else { return nil }
        if isReadOnly(document) { return document }
        guard validate(document) == nil else { return nil }
        return document
    }

    static func serialize(_ document: SyncRulesDocument) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try? encoder.encode(document)
    }

    /// True when the entry carries rich text whose HTML fragment contains the
    /// ordinal substring `data:image/`.
    static func entryHasEmbeddedImage(_ entry: ClipEntry) -> Bool {
        guard let fragment = entry.RichText?.HtmlFragment, !fragment.isEmpty else { return false }
        return fragment.range(of: dataImagePrefix, options: [.literal]) != nil
    }

    private static func routeMatches(_ route: SyncRoute, _ entry: ClipEntry) -> Bool {
        var hasCondition = false

        if let groups = route.Groups, !groups.isEmpty {
            hasCondition = true
            if !containsNormalized(groups, entry.Group) { return false }
        }
        if let sourceDevices = route.SourceDevices, !sourceDevices.isEmpty {
            hasCondition = true
            if !containsNormalized(sourceDevices, entry.SourceMachine) { return false }
        }
        if let kind = route.Kind, !kind.isEmpty {
            hasCondition = true
            if kind != richTextImagesKind || !entryHasEmbeddedImage(entry) { return false }
        }

        return hasCondition
    }

    private static func containsNormalized(_ values: [String], _ candidate: String) -> Bool {
        let target = normalized(candidate)
        return values.contains { normalized($0) == target }
    }

    private static func isWildcard(_ reference: String) -> Bool {
        reference.trimmingCharacters(in: .whitespacesAndNewlines) == "*"
    }

    /// Byte-wise ordering of the UTF-8 encodings, which is the ordinal
    /// comparison the tie-break rule of spec section 4 calls for. Swift's native
    /// `<` on `String` orders by Unicode canonical equivalence instead.
    private static func ordinalCompare(_ left: String, _ right: String) -> Int {
        let leftBytes = Array(left.utf8)
        let rightBytes = Array(right.utf8)
        if leftBytes.lexicographicallyPrecedes(rightBytes) { return -1 }
        if rightBytes.lexicographicallyPrecedes(leftBytes) { return 1 }
        return 0
    }

    /// `[a-z0-9]([a-z0-9 _-]{0,30}[a-z0-9])?`, ASCII only, 1 to 32 characters.
    /// Written out rather than compiled as a regular expression so the grammar is
    /// identical on every platform and cannot pick up Unicode character classes.
    private static func matchesChannelKeyGrammar(_ key: String) -> Bool {
        guard key.unicodeScalars.allSatisfy({ $0.isASCII }) else { return false }
        let bytes = Array(key.utf8)
        guard bytes.count >= 1, bytes.count <= 32 else { return false }
        guard isChannelKeyEdge(bytes[0]) else { return false }
        if bytes.count == 1 { return true }
        guard isChannelKeyEdge(bytes[bytes.count - 1]) else { return false }
        for index in 1..<(bytes.count - 1) where !isChannelKeyInterior(bytes[index]) {
            return false
        }
        return true
    }

    private static func isChannelKeyEdge(_ byte: UInt8) -> Bool {
        (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
            || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
    }

    private static func isChannelKeyInterior(_ byte: UInt8) -> Bool {
        isChannelKeyEdge(byte)
            || byte == UInt8(ascii: " ")
            || byte == UInt8(ascii: "_")
            || byte == UInt8(ascii: "-")
    }
}

// MARK: - Multi-channel assembly

/// One channel's contents as they stood at the last transfer. `key` is `""` for
/// the core channel.
struct SyncChannelSnapshot: Sendable, Equatable {
    var key: String
    var database: ClipDatabase

    init(key: String, database: ClipDatabase) {
        self.key = key
        self.database = database
    }
}

/// The per-channel entry assignment one save produces, in the two phases of
/// `sync-rules-spec.md` section 5, upload step 5.
struct SyncChannelUploadPlan: Sendable {
    /// The final assignment: what each channel keeps (phase two).
    var routed: [String: [ClipEntry]] = [:]
    /// The phase-one assignment: what each channel keeps plus the copies of the
    /// entries it is about to lose, exactly as it was fetched with them.
    var withDepartures: [String: [ClipEntry]] = [:]
    /// What each channel loses in this save.
    var departures: [String: [ClipEntry]] = [:]
    /// The relocation markers each losing channel gains in phase two.
    var relocations: [String: [DeletedClipEntry]] = [:]
    /// Entries bound for channels this device does not subscribe to.
    var pending: [String: [ClipEntry]] = [:]
    /// `pending`'s keys in first-seen order.
    var pendingKeys: [String] = []
}

/// The download half of `sync-rules-spec.md` section 5 (cross-channel view
/// assembly) plus the pure parts of the upload half: routing, relocation, marker
/// filing and the durable dirty-detection hash. Everything here is a pure
/// function of its inputs so it can be exercised without a server.
enum SyncChannelAssembler {
    /// The case-insensitive comparison form the entry merge uses for entry and
    /// tombstone ids.
    static func comparableID(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Merges the per-channel databases into the single view of spec section 5,
    /// download steps 3 and 4, and records which channel each surviving entry
    /// came from.
    ///
    /// Cross-channel assembly deliberately does not use the entry-level field
    /// merge or text-fallback matching: an `Id` collision is a move race, so the
    /// copy with the lower `ModifiedUnixMs` is dropped wholesale and a tie goes
    /// to the earlier channel in assembly order.
    static func buildView(_ channels: [SyncChannelSnapshot]) -> (view: ClipDatabase, residence: [String: String]) {
        var view = ClipDatabase()
        var entries: [ClipEntry] = []
        var owners: [String] = []
        var indexByID: [String: Int] = [:]

        for channel in channels {
            view.Version = max(view.Version, channel.database.Version)
            for entry in channel.database.Entries {
                let identifier = comparableID(entry.Id)
                if !identifier.isEmpty, let index = indexByID[identifier] {
                    if entry.ModifiedUnixMs > entries[index].ModifiedUnixMs {
                        entries[index] = entry
                        owners[index] = channel.key
                    }
                    continue
                }
                entries.append(entry)
                owners.append(channel.key)
                if !identifier.isEmpty {
                    indexByID[identifier] = entries.count - 1
                }
            }
        }

        // Tombstones apply within their own channel only, with one exception: a
        // marker with a non-empty TextHash also suppresses matching-text entries
        // in other channels. A relocation marker (empty TextHash) never does.
        var suppressed = [Bool](repeating: false, count: entries.count)
        for channel in channels {
            for marker in channel.database.DeletedEntries where !marker.TextHash.isEmpty {
                for index in entries.indices where !suppressed[index] && owners[index] != channel.key {
                    if textMarkerSuppresses(marker, entries[index]) {
                        suppressed[index] = true
                    }
                }
            }
        }

        var survivors: [ClipEntry] = []
        var survivorOwners: [String] = []
        var residence: [String: String] = [:]
        var live = Set<String>()
        for index in entries.indices where !suppressed[index] {
            survivors.append(entries[index])
            survivorOwners.append(owners[index])
            residence[entries[index].Id] = owners[index]
            live.insert(comparableID(entries[index].Id))
        }
        view.Entries = survivors
        applyCombinedManualOrder(&view.Entries, owners: survivorOwners)

        // The view carries every channel's markers, except those contradicted by
        // a live entry elsewhere: a relocation marker names an id that now lives
        // in another channel, and applying it to the view would delete the entry
        // it only meant to move.
        var markers: [DeletedClipEntry] = []
        for channel in channels {
            for marker in channel.database.DeletedEntries where !live.contains(comparableID(marker.Id)) {
                markers.append(marker)
            }
        }
        view.DeletedEntries = markers
        view = SyncConflictResolver.normalized(view)

        var finalResidence: [String: String] = [:]
        for entry in view.Entries {
            if let key = residence[entry.Id] {
                finalResidence[entry.Id] = key
            }
        }
        return (view, finalResidence)
    }

    /// Merges channel-local manual sequences by creation time. Every channel's
    /// own order is retained, while a new channel's first item no longer jumps
    /// ahead of older entries merely because both have ManualOrder 1.
    private static func applyCombinedManualOrder(_ entries: inout [ClipEntry], owners: [String]) {
        var sequences: [[Int]] = []
        var sequenceByOwner: [String: Int] = [:]
        for (index, owner) in owners.enumerated() {
            let sequenceIndex: Int
            if let existing = sequenceByOwner[owner] {
                sequenceIndex = existing
            } else {
                sequenceIndex = sequences.count
                sequenceByOwner[owner] = sequenceIndex
                sequences.append([])
            }
            sequences[sequenceIndex].append(index)
        }
        for index in sequences.indices {
            sequences[index].sort {
                let left = entries[$0]
                let right = entries[$1]
                let leftOrder = left.ManualOrder <= 0 ? Int64.max : left.ManualOrder
                let rightOrder = right.ManualOrder <= 0 ? Int64.max : right.ManualOrder
                if leftOrder != rightOrder { return leftOrder < rightOrder }
                if left.CreatedUnixMs != right.CreatedUnixMs { return left.CreatedUnixMs < right.CreatedUnixMs }
                return left.Id < right.Id
            }
        }

        var offsets = [Int](repeating: 0, count: sequences.count)
        var ordered: [ClipEntry] = []
        ordered.reserveCapacity(entries.count)
        while ordered.count < entries.count {
            var chosen: Int?
            var chosenCreated = Int64.max
            for index in sequences.indices where offsets[index] < sequences[index].count {
                let entry = entries[sequences[index][offsets[index]]]
                let created = entry.CreatedUnixMs <= 0 ? Int64.max : entry.CreatedUnixMs
                if chosen == nil || created < chosenCreated {
                    chosen = index
                    chosenCreated = created
                }
            }
            guard let chosen else { break }
            var entry = entries[sequences[chosen][offsets[chosen]]]
            offsets[chosen] += 1
            entry.ManualOrder = Int64(ordered.count + 1)
            ordered.append(entry)
        }
        entries = ordered
    }

    /// The text-hash half of the entry-level deletion rule, which is the only
    /// tombstone rule that reaches across channel boundaries.
    static func textMarkerSuppresses(_ marker: DeletedClipEntry, _ entry: ClipEntry) -> Bool {
        guard !marker.TextHash.isEmpty, !entry.Text.isEmpty,
              marker.TextHash.caseInsensitiveCompare(SyncConflictResolver.textHash(entry.Text)) == .orderedSame else {
            return false
        }
        let changed = max(entry.CreatedUnixMs, entry.LastUsedUnixMs, entry.ModifiedUnixMs)
        return marker.DeletedUnixMs <= 0 || changed <= marker.DeletedUnixMs
    }

    /// Routing, relocation and write-through assignment (spec section 5, upload
    /// steps 1 to 3, and section 6). `entries` is the merged view plus any
    /// parked write-through entries; parked entries have no residence, so they
    /// never produce a departure. `fetched` maps a channel key to its entries as
    /// they were downloaded, keyed by comparable id.
    static func plan(
        entries: [ClipEntry],
        document: SyncRulesDocument?,
        residence: [String: String],
        fetched: [String: [String: ClipEntry]],
        subscribed: Set<String>,
        deviceName: String,
        now: Int64
    ) -> SyncChannelUploadPlan {
        var plan = SyncChannelUploadPlan()
        for entry in entries {
            let target = SyncRuleEngine.route(document: document, entry: entry)
            if let source = residence[entry.Id], source != target {
                plan.departures[source, default: []].append(entry)
                plan.relocations[source, default: []].append(DeletedClipEntry(
                    Id: entry.Id,
                    TextHash: "",
                    DeletedUnixMs: now,
                    SourceMachine: deviceName
                ))
            }
            if subscribed.contains(target) {
                plan.routed[target, default: []].append(entry)
                continue
            }
            if plan.pending[target] == nil {
                plan.pendingKeys.append(target)
            }
            plan.pending[target, default: []].append(entry)
        }
        plan.withDepartures = withDepartures(
            routed: plan.routed,
            departures: plan.departures,
            fetched: fetched
        )
        return plan
    }

    /// Cancels one entry's departure, which is what a failed write-through must
    /// do: the entry stays where it already lives instead of being taken away
    /// from the only channel that holds it (spec section 6).
    static func cancelDeparture(_ plan: inout SyncChannelUploadPlan, entry: ClipEntry, source: String) {
        plan.routed[source, default: []].append(entry)
        let identifier = comparableID(entry.Id)
        plan.departures[source] = (plan.departures[source] ?? []).filter { comparableID($0.Id) != identifier }
        plan.relocations[source] = (plan.relocations[source] ?? []).filter { comparableID($0.Id) != identifier }
    }

    /// The phase-one entry assignment: what each channel keeps plus what it is
    /// about to lose, so the first upload of a save only ever adds.
    ///
    /// A departing entry is carried in the copy the channel was fetched with, not
    /// the locally modified one. The target receives the modified copy in the
    /// same phase, and its higher `ModifiedUnixMs` wins view assembly for the
    /// transient window in which both channels hold the id. Keeping the fetched
    /// copy is what lets a channel whose only change is a departure hash clean
    /// and skip its phase-one upload.
    static func withDepartures(
        routed: [String: [ClipEntry]],
        departures: [String: [ClipEntry]],
        fetched: [String: [String: ClipEntry]]
    ) -> [String: [ClipEntry]] {
        guard !departures.isEmpty else { return routed }
        var combined = routed
        for (key, leaving) in departures where !leaving.isEmpty {
            var staying = combined[key] ?? []
            for entry in leaving {
                staying.append(fetched[key]?[comparableID(entry.Id)] ?? entry)
            }
            combined[key] = staying
        }
        return combined
    }

    /// Each channel's entries as they were downloaded, keyed by comparable id.
    static func fetchedEntries(_ channels: [SyncChannelSnapshot]) -> [String: [String: ClipEntry]] {
        var byChannel: [String: [String: ClipEntry]] = [:]
        for channel in channels {
            var entries: [String: ClipEntry] = [:]
            for entry in channel.database.Entries {
                entries[comparableID(entry.Id)] = entry
            }
            byChannel[channel.key] = entries
        }
        return byChannel
    }

    /// Files tombstones per channel. Tombstones are channel-local: each channel
    /// keeps the markers it already carried, and only markers this mutation
    /// created or refreshed are filed against the channel the entry lived in.
    /// Relocation markers are added last, for the channels their entries left.
    static func markers(
        channels: [SyncChannelSnapshot],
        viewMarkers: [DeletedClipEntry],
        previousMarkers: [String: DeletedClipEntry],
        residence: [String: String],
        subscribed: Set<String>,
        relocations: [String: [DeletedClipEntry]]?
    ) -> [String: [DeletedClipEntry]] {
        var markers: [String: [DeletedClipEntry]] = [:]
        for channel in channels {
            markers[channel.key] = channel.database.DeletedEntries
        }
        for marker in viewMarkers {
            if let before = previousMarkers[comparableID(marker.Id)],
               before.DeletedUnixMs == marker.DeletedUnixMs,
               before.TextHash == marker.TextHash {
                continue
            }
            var home = residence[marker.Id] ?? SyncRuleEngine.coreChannelKey
            if !subscribed.contains(home) { home = SyncRuleEngine.coreChannelKey }
            markers[home, default: []].append(marker)
        }
        if let relocations {
            for key in relocations.keys.sorted() where subscribed.contains(key) {
                markers[key, default: []].append(contentsOf: relocations[key] ?? [])
            }
        }
        // One marker per id per channel, last filed wins: a marker this mutation
        // created replaces the one the channel already carried, and a relocation
        // marker replaces an older deletion marker for the same id. Leaving both
        // in place would let normalization back-fill the relocation marker's
        // deliberately empty TextHash from the older one, which would then
        // suppress the entry in the channel it just moved to.
        for key in markers.keys.sorted() {
            let filed = markers[key] ?? []
            guard filed.count > 1 else { continue }
            var lastIndexByID: [String: Int] = [:]
            for (index, marker) in filed.enumerated() {
                lastIndexByID[comparableID(marker.Id)] = index
            }
            markers[key] = filed.enumerated()
                .filter { lastIndexByID[comparableID($0.element.Id)] == $0.offset }
                .map(\.element)
        }
        return markers
    }

    /// Rebuilds one database per channel from the routed entries and the markers
    /// filed against it, in `channels` order.
    static func channelDatabases(
        channels: [SyncChannelSnapshot],
        routed: [String: [ClipEntry]],
        markers: [String: [DeletedClipEntry]],
        now: Int64
    ) -> [ClipDatabase] {
        channels.map { channel in
            let entries = routed[channel.key] ?? []
            var database = ClipDatabase(
                Version: max(1, channel.database.Version),
                UpdatedUnixMs: now,
                Entries: entries,
                DeletedEntries: dropMarkers(markers[channel.key] ?? [], forEntries: entries)
            )
            database = SyncConflictResolver.normalized(database)
            database.UpdatedUnixMs = now
            return database
        }
    }

    /// Removes markers naming an entry that is being written into the same
    /// channel. Without this a relocation marker left behind by an earlier move
    /// would delete the entry again when a rule change moves it back.
    static func dropMarkers(_ markers: [DeletedClipEntry], forEntries entries: [ClipEntry]) -> [DeletedClipEntry] {
        guard !markers.isEmpty, !entries.isEmpty else { return markers }
        let resident = Set(entries.map { comparableID($0.Id) })
        return markers.filter { !resident.contains(comparableID($0.Id)) }
    }

    /// Tombstones indexed by comparable id, so a mutation can be told apart from
    /// an unchanged marker it merely read.
    static func markersByID(_ markers: [DeletedClipEntry]) -> [String: DeletedClipEntry] {
        var byID: [String: DeletedClipEntry] = [:]
        for marker in markers {
            byID[comparableID(marker.Id)] = marker
        }
        return byID
    }

    /// The dirty-detection hash of spec section 5, upload step 4: the SHA-256 of
    /// the deterministic plaintext JSON with the database-level `UpdatedUnixMs`
    /// zeroed. Zeroing it is what makes the hash durable, because normalization
    /// restamps that field on every pass, so two reads of an unchanged bucket at
    /// different times still hash alike.
    ///
    /// The comparison must happen on plaintext: ciphertext differs on every
    /// encode because the initialization vector is fresh.
    static func durableHash(_ database: ClipDatabase) -> String {
        var durable = database
        durable.UpdatedUnixMs = 0
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let encoded = try? encoder.encode(durable) else { return "" }
        return SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
    }
}
