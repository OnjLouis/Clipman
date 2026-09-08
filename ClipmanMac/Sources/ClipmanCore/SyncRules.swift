import Foundation

/// The sync-rules document of `sync-rules-spec.md` section 4: named channels,
/// the routes that fill them, and per-device subscriptions. It is stored in its
/// own bucket (server mode) or its own sibling file (shared-folder mode), never
/// inside the history database, because clients drop unknown JSON fields when
/// they save a `ClipDatabase`.
public struct SyncRulesDocument: Codable, Equatable, Sendable {
    public var Clipman: String
    public var Version: Int
    public var Enabled: Bool
    public var UpdatedUnixMs: Int64
    public var UpdatedBy: String
    public var Channels: [SyncChannel]
    public var Devices: [SyncDevice]
    /// Top-level fields this version does not understand, kept verbatim so a
    /// save from here never silently drops what a newer client wrote.
    public var unknownFields: [String: JSONValue]

    public init(
        Clipman: String = SyncRuleEngine.documentKind,
        Version: Int = SyncRuleEngine.currentVersion,
        Enabled: Bool = false,
        UpdatedUnixMs: Int64 = 0,
        UpdatedBy: String = "",
        Channels: [SyncChannel] = [],
        Devices: [SyncDevice] = [],
        unknownFields: [String: JSONValue] = [:]
    ) {
        self.Clipman = Clipman
        self.Version = Version
        self.Enabled = Enabled
        self.UpdatedUnixMs = UpdatedUnixMs
        self.UpdatedBy = UpdatedBy
        self.Channels = Channels
        self.Devices = Devices
        self.unknownFields = unknownFields
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case Clipman, Version, Enabled, UpdatedUnixMs, UpdatedBy, Channels, Devices
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        Clipman = try container.decodeIfPresent(String.self, forKey: .Clipman) ?? ""
        Version = try container.decodeIfPresent(Int.self, forKey: .Version) ?? SyncRuleEngine.currentVersion
        Enabled = try container.decodeIfPresent(Bool.self, forKey: .Enabled) ?? false
        UpdatedUnixMs = try container.decodeIfPresent(Int64.self, forKey: .UpdatedUnixMs) ?? 0
        UpdatedBy = try container.decodeIfPresent(String.self, forKey: .UpdatedBy) ?? ""
        Channels = try container.decodeIfPresent([SyncChannel].self, forKey: .Channels) ?? []
        Devices = try container.decodeIfPresent([SyncDevice].self, forKey: .Devices) ?? []

        let dynamic = try decoder.container(keyedBy: DynamicCodingKey.self)
        let knownNames = Set(CodingKeys.allCases.map(\.rawValue))
        var extra: [String: JSONValue] = [:]
        for key in dynamic.allKeys where !knownNames.contains(key.stringValue) {
            extra[key.stringValue] = try dynamic.decode(JSONValue.self, forKey: key)
        }
        unknownFields = extra
    }

    public func encode(to encoder: Encoder) throws {
        var dynamic = encoder.container(keyedBy: DynamicCodingKey.self)
        // Sorted so serialization stays deterministic even under an encoder
        // that preserves insertion order.
        for key in unknownFields.keys.sorted() {
            guard let value = unknownFields[key] else { continue }
            try dynamic.encode(value, forKey: DynamicCodingKey(key))
        }
        try dynamic.encode(Clipman, forKey: DynamicCodingKey("Clipman"))
        try dynamic.encode(Version, forKey: DynamicCodingKey("Version"))
        try dynamic.encode(Enabled, forKey: DynamicCodingKey("Enabled"))
        try dynamic.encode(UpdatedUnixMs, forKey: DynamicCodingKey("UpdatedUnixMs"))
        try dynamic.encode(UpdatedBy, forKey: DynamicCodingKey("UpdatedBy"))
        try dynamic.encode(Channels, forKey: DynamicCodingKey("Channels"))
        try dynamic.encode(Devices, forKey: DynamicCodingKey("Devices"))
    }
}

/// One named partition of history together with the route that fills it.
public struct SyncChannel: Codable, Equatable, Sendable {
    public var Name: String
    public var Route: SyncRoute

    public init(Name: String = "", Route: SyncRoute = SyncRoute()) {
        self.Name = Name
        self.Route = Route
    }

    private enum CodingKeys: String, CodingKey {
        case Name, Route
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        Name = try container.decodeIfPresent(String.self, forKey: .Name) ?? ""
        Route = try container.decodeIfPresent(SyncRoute.self, forKey: .Route) ?? SyncRoute()
    }
}

/// The conditions, ANDed together, that route an entry into its channel. A
/// route with no condition set never matches; `validate` rejects such routes,
/// but routing must stay safe against an unvalidated future document.
public struct SyncRoute: Codable, Equatable, Sendable {
    public var Groups: [String]?
    public var SourceDevices: [String]?
    public var Kind: String?

    public init(Groups: [String]? = nil, SourceDevices: [String]? = nil, Kind: String? = nil) {
        self.Groups = Groups
        self.SourceDevices = SourceDevices
        self.Kind = Kind
    }

    private enum CodingKeys: String, CodingKey {
        case Groups, SourceDevices, Kind
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        Groups = try container.decodeIfPresent([String].self, forKey: .Groups)
        SourceDevices = try container.decodeIfPresent([String].self, forKey: .SourceDevices)
        Kind = try container.decodeIfPresent(String.self, forKey: .Kind)
    }

    /// Mirrors the reference implementation's `omitempty`: absent, empty and
    /// blank conditions are not written back out.
    public func encode(to encoder: Encoder) throws {
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
public struct SyncDevice: Codable, Equatable, Sendable {
    public var Name: String
    public var Channels: [String]

    public init(Name: String = "", Channels: [String] = []) {
        self.Name = Name
        self.Channels = Channels
    }

    private enum CodingKeys: String, CodingKey {
        case Name, Channels
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        Name = try container.decodeIfPresent(String.self, forKey: .Name) ?? ""
        Channels = try container.decodeIfPresent([String].self, forKey: .Channels) ?? []
    }
}

/// Entries captured on this device that route to a channel it does not
/// subscribe to and whose write-through failed (spec section 6). They are kept
/// beside the history database and retried after the next successful poll; they
/// never appear in the local view.
public struct PendingChannelWrites: Codable, Equatable, Sendable {
    public var Channels: [PendingChannelWrite]

    public init(Channels: [PendingChannelWrite] = []) {
        self.Channels = Channels
    }

    private enum CodingKeys: String, CodingKey {
        case Channels
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        Channels = try container.decodeIfPresent([PendingChannelWrite].self, forKey: .Channels) ?? []
    }
}

public struct PendingChannelWrite: Codable, Equatable, Sendable {
    public var ChannelKey: String
    public var Entries: [ClipEntry]

    public init(ChannelKey: String = "", Entries: [ClipEntry] = []) {
        self.ChannelKey = ChannelKey
        self.Entries = Entries
    }

    private enum CodingKeys: String, CodingKey {
        case ChannelKey, Entries
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ChannelKey = try container.decodeIfPresent(String.self, forKey: .ChannelKey) ?? ""
        Entries = try container.decodeIfPresent([ClipEntry].self, forKey: .Entries) ?? []
    }
}

/// Channel key derivation, document validation, per-entry routing, device
/// subscriptions and whole-document last-writer-wins merge, exactly as
/// `sync-rules-spec.md` sections 3 and 4 require. Every client must produce the
/// same answers here or the same entry would land in different channels on
/// different devices.
public enum SyncRuleEngine {
    public static let documentKind = "sync-rules"
    public static let currentVersion = 1
    public static let richTextImagesKind = "RichTextImages"
    public static let coreChannelKey = ""
    public static let syncRulesFileName = "clipman-sync-rules.clipdb"
    public static let pendingChannelWritesFileName = "clipman-pending-channels.clipdb"
    public static let channelFilePrefix = "clipman-channel-"
    public static let channelFileSuffix = ".clipdb"

    private static let dataImagePrefix = "data:image/"
    private static let reservedChannelKeys: Set<String> = ["core", "all", "pinned", "sync-rules"]

    /// The `lowerInvariant(trim(x))` comparison rule used throughout spec
    /// section 3 for channel keys, device names and groups. `lowercased()` is
    /// Unicode-aware but locale-independent, and channel keys are ASCII-only by
    /// grammar, so it is an adequate invariant lowering here. Device and group
    /// matching accepts the spec's stated tolerance for that difference.
    public static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The channel key for a display name: `lowerInvariant(trim(Name))` when it
    /// matches `[a-z0-9]([a-z0-9 _-]{0,30}[a-z0-9])?` and is pure ASCII, and
    /// `""` (meaning "not a usable channel") otherwise.
    public static func channelKey(_ name: String) -> String {
        let key = normalized(name)
        return matchesChannelKeyGrammar(key) ? key : ""
    }

    /// The channel key as it appears in shared-folder file names, where spaces
    /// become dashes (spec section 2). Two distinct keys can fold to the same
    /// storage name - "my work" and "my-work" - and would then share one file,
    /// so `validate` rejects that at edit time.
    public static func channelStorageName(_ key: String) -> String {
        key.replacingOccurrences(of: " ", with: "-")
    }

    /// The shared-folder sibling file name for a channel key (spec section 2).
    public static func channelFileName(_ key: String) -> String {
        channelFilePrefix + channelStorageName(key) + channelFileSuffix
    }

    /// True when the name is some channel's storage file rather than a sync
    /// service's conflict copy of one. Used to keep conflict-copy resolution
    /// from ever merging one channel into another.
    public static func isChannelFileName(_ name: String) -> Bool {
        let lower = name.lowercased()
        guard lower.hasPrefix(channelFilePrefix),
              lower.hasSuffix(channelFileSuffix),
              lower.count > channelFilePrefix.count + channelFileSuffix.count else {
            return false
        }
        let storageName = String(lower.dropFirst(channelFilePrefix.count).dropLast(channelFileSuffix.count))
        // The storage alphabet is a subset of the key alphabet - spaces fold to
        // dashes, which keys already allow - so a valid key means a real channel
        // file, and anything a sync service appended fails the grammar.
        return !channelKey(storageName).isEmpty
    }

    /// A document written by a future format version is applied where it is
    /// understood but never rewritten by this client (spec section 4, Version).
    public static func isReadOnly(_ document: SyncRulesDocument?) -> Bool {
        guard let document else { return false }
        return document.Version > currentVersion
    }

    /// Whether a document read from storage may be applied. A future-version
    /// document is accepted leniently - a client must never fail entirely on a
    /// document it only partly understands - while a current-version document
    /// must still pass strict validation, since editors validate before writing.
    /// The folded-storage-name collision is an edit-time rule only: a document
    /// already saved with such a collision must still load and route.
    public static func isUsable(_ document: SyncRulesDocument?) -> Bool {
        guard let document, document.Clipman == documentKind else { return false }
        if isReadOnly(document) { return true }
        return validate(document, enforceStorageNameCollisions: false) == nil
    }

    /// Returns nil when the document is valid, or a display-ready reason.
    public static func validate(_ document: SyncRulesDocument?) -> String? {
        validate(document, enforceStorageNameCollisions: true)
    }

    /// `enforceStorageNameCollisions` gates the folded-storage-name check of
    /// spec section 2 (two channel keys that share one shared-folder file name).
    /// Editors enforce it; the read path does not, so a document already saved
    /// with such a collision keeps loading and routing.
    public static func validate(_ document: SyncRulesDocument?, enforceStorageNameCollisions: Bool) -> String? {
        guard let document else { return "The sync rules document is missing." }
        guard document.Clipman == documentKind else {
            return "The sync rules document has an unrecognized format."
        }

        var knownKeys = Set<String>()
        var storageNames = Set<String>()
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
            if !storageNames.insert(channelStorageName(key)).inserted, enforceStorageNameCollisions {
                return "Channel name \"\(channel.Name)\" would share a storage file with another channel. Spaces and dashes are interchangeable in channel file names."
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
    /// entry, or `""` when the document is missing, disabled, or nothing
    /// matches - meaning the entry lives in core.
    ///
    /// A matching channel whose name yields no valid key resolves to `""` as
    /// well, exactly as the reference implementation does: such a channel can
    /// only come from a future-version document, and stopping there keeps the
    /// entry in core rather than filing it under a later, unrelated rule.
    public static func route(document: SyncRulesDocument?, entry: ClipEntry?) -> String {
        guard let document, document.Enabled, let entry else { return coreChannelKey }
        for channel in document.Channels where routeMatches(channel.Route, entry) {
            return channelKey(channel.Name)
        }
        return coreChannelKey
    }

    /// The channel an entry belongs in during a save, given where it currently
    /// lives. Spec section 4: a read-only (future-version) document never
    /// triggers relocation, because a client that cannot fully evaluate the
    /// rules must not fight better-informed clients over placement - every
    /// resident entry keeps its channel and only new captures are routed.
    public static func target(document: SyncRulesDocument?, entry: ClipEntry, residence: String?) -> String {
        if isReadOnly(document), let residence {
            return residence
        }
        return route(document: document, entry: entry)
    }

    /// The channel keys the named device downloads besides core, in document
    /// order. Returns nil when the document is missing, disabled, or the device
    /// is not listed - nil means "subscribe to everything" (spec section 4).
    public static func subscribedChannels(document: SyncRulesDocument?, deviceName: String) -> [String]? {
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
    public static func allChannelKeys(_ document: SyncRulesDocument?) -> [String] {
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
    public static func channelName(_ document: SyncRulesDocument?, key: String) -> String {
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
    public static func subscribedKeys(document: SyncRulesDocument?, deviceName: String) -> [String] {
        guard let document, document.Enabled else { return [] }
        let subscribed = subscribedChannels(document: document, deviceName: deviceName)
        guard let subscribed else { return allChannelKeys(document) }
        let wanted = Set(subscribed)
        return allChannelKeys(document).filter { wanted.contains($0) }
    }

    /// Whole-document last-writer-wins on `UpdatedUnixMs`, breaking ties toward
    /// the greater `UpdatedBy` by ordinal comparison. A nil document loses to a
    /// non-nil one; two nil documents merge to nil.
    public static func merge(local: SyncRulesDocument?, remote: SyncRulesDocument?) -> SyncRulesDocument? {
        guard let local else { return remote }
        guard let remote else { return local }
        if remote.UpdatedUnixMs > local.UpdatedUnixMs { return remote }
        if remote.UpdatedUnixMs < local.UpdatedUnixMs { return local }
        return ordinalCompare(remote.UpdatedBy, local.UpdatedBy) > 0 ? remote : local
    }

    /// Decodes a rules document, rejecting any payload whose `Clipman` field is
    /// not `sync-rules`. A future-version document skips strict validation so a
    /// client never fails entirely on a document it only partly understands.
    public static func parse(_ data: Data) -> SyncRulesDocument? {
        guard let document = try? JSONDecoder().decode(SyncRulesDocument.self, from: data) else {
            return nil
        }
        guard document.Clipman == documentKind else { return nil }
        if isReadOnly(document) { return document }
        // The read path tolerates a folded-storage-name collision, so a document
        // some other editor already saved keeps loading.
        guard validate(document, enforceStorageNameCollisions: false) == nil else { return nil }
        return document
    }

    public static func serialize(_ document: SyncRulesDocument) -> Data? {
        let encoder = JSONEncoder()
        // Sorted so equal documents always produce equal bytes, including inside
        // preserved unknown fields: the cache-hash comparisons that decide
        // whether the rules file must be rewritten depend on it.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(document)
    }

    /// True when the entry carries rich text whose HTML fragment contains the
    /// ordinal substring `data:image/`.
    public static func entryHasEmbeddedImage(_ entry: ClipEntry) -> Bool {
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
    /// comparison the tie-break rule of spec section 4 calls for. Swift's
    /// native `<` on `String` orders by Unicode canonical equivalence instead.
    private static func ordinalCompare(_ left: String, _ right: String) -> Int {
        let leftBytes = Array(left.utf8)
        let rightBytes = Array(right.utf8)
        if leftBytes.lexicographicallyPrecedes(rightBytes) { return -1 }
        if rightBytes.lexicographicallyPrecedes(leftBytes) { return 1 }
        return 0
    }

    /// `[a-z0-9]([a-z0-9 _-]{0,30}[a-z0-9])?`, ASCII only, 1 to 32 characters.
    /// Written out rather than compiled as a regular expression so the grammar
    /// is identical on every platform and cannot pick up Unicode character
    /// classes.
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

/// Deterministically combines the independent manual-order sequences stored in
/// subscribed channel databases into the one order shown by a client.
public enum SyncChannelManualOrder {
    public static func merged(_ entries: [ClipEntry], owners: [String]) -> [ClipEntry] {
        precondition(entries.count == owners.count)
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
        return ordered
    }
}
