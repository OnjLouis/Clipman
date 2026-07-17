import Foundation

public struct ClipEntry: Codable, Identifiable, Equatable, Sendable {
    public var Id: String
    public var Text: String
    public var Name: String
    public var Group: String
    public var SourceMachine: String
    public var CreatedUnixMs: Int64
    public var LastUsedUnixMs: Int64
    public var Pinned: Bool
    public var IsTemplate: Bool
    public var ManualOrder: Int64
    public var unknownFields: [String: JSONValue]

    public var id: String { Id }

    public init(
        Id: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
        Text: String = "",
        Name: String = "",
        Group: String = "",
        SourceMachine: String = "",
        CreatedUnixMs: Int64 = TimeUtil.nowUnixMs(),
        LastUsedUnixMs: Int64 = TimeUtil.nowUnixMs(),
        Pinned: Bool = false,
        IsTemplate: Bool = false,
        ManualOrder: Int64 = 0,
        unknownFields: [String: JSONValue] = [:]
    ) {
        self.Id = Id
        self.Text = Text
        self.Name = Name
        self.Group = Group
        self.SourceMachine = SourceMachine
        self.CreatedUnixMs = CreatedUnixMs
        self.LastUsedUnixMs = LastUsedUnixMs
        self.Pinned = Pinned
        self.IsTemplate = IsTemplate
        self.ManualOrder = ManualOrder
        self.unknownFields = unknownFields
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case Id, Text, Name, Group, SourceMachine, CreatedUnixMs, LastUsedUnixMs, Pinned, IsTemplate, ManualOrder
    }

    public init(from decoder: Decoder) throws {
        let known = try decoder.container(keyedBy: CodingKeys.self)
        Id = try known.decodeIfPresent(String.self, forKey: .Id) ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        Text = try known.decodeIfPresent(String.self, forKey: .Text) ?? ""
        Name = try known.decodeIfPresent(String.self, forKey: .Name) ?? ""
        Group = try known.decodeIfPresent(String.self, forKey: .Group) ?? ""
        SourceMachine = try known.decodeIfPresent(String.self, forKey: .SourceMachine) ?? ""
        CreatedUnixMs = try known.decodeIfPresent(Int64.self, forKey: .CreatedUnixMs) ?? TimeUtil.nowUnixMs()
        LastUsedUnixMs = try known.decodeIfPresent(Int64.self, forKey: .LastUsedUnixMs) ?? CreatedUnixMs
        Pinned = try known.decodeIfPresent(Bool.self, forKey: .Pinned) ?? false
        IsTemplate = try known.decodeIfPresent(Bool.self, forKey: .IsTemplate) ?? false
        ManualOrder = try known.decodeIfPresent(Int64.self, forKey: .ManualOrder) ?? 0

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
        for (key, value) in unknownFields {
            try dynamic.encode(value, forKey: DynamicCodingKey(key))
        }
        try dynamic.encode(Id, forKey: DynamicCodingKey("Id"))
        try dynamic.encode(Text, forKey: DynamicCodingKey("Text"))
        try dynamic.encode(Name, forKey: DynamicCodingKey("Name"))
        try dynamic.encode(Group, forKey: DynamicCodingKey("Group"))
        try dynamic.encode(SourceMachine, forKey: DynamicCodingKey("SourceMachine"))
        try dynamic.encode(CreatedUnixMs, forKey: DynamicCodingKey("CreatedUnixMs"))
        try dynamic.encode(LastUsedUnixMs, forKey: DynamicCodingKey("LastUsedUnixMs"))
        try dynamic.encode(Pinned, forKey: DynamicCodingKey("Pinned"))
        try dynamic.encode(IsTemplate, forKey: DynamicCodingKey("IsTemplate"))
        try dynamic.encode(ManualOrder, forKey: DynamicCodingKey("ManualOrder"))
    }
}

public struct ClipDatabase: Codable, Equatable, Sendable {
    public var Version: Int
    public var UpdatedUnixMs: Int64
    public var Entries: [ClipEntry]
    public var DeletedEntries: [DeletedClipEntry]
    public var unknownFields: [String: JSONValue]

    public init(
        Version: Int = 1,
        UpdatedUnixMs: Int64 = TimeUtil.nowUnixMs(),
        Entries: [ClipEntry] = [],
        DeletedEntries: [DeletedClipEntry] = [],
        unknownFields: [String: JSONValue] = [:]
    ) {
        self.Version = Version
        self.UpdatedUnixMs = UpdatedUnixMs
        self.Entries = Entries
        self.DeletedEntries = DeletedEntries
        self.unknownFields = unknownFields
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case Version, UpdatedUnixMs, Entries, DeletedEntries
    }

    public init(from decoder: Decoder) throws {
        let known = try decoder.container(keyedBy: CodingKeys.self)
        Version = try known.decodeIfPresent(Int.self, forKey: .Version) ?? 1
        UpdatedUnixMs = try known.decodeIfPresent(Int64.self, forKey: .UpdatedUnixMs) ?? TimeUtil.nowUnixMs()
        Entries = try known.decodeIfPresent([ClipEntry].self, forKey: .Entries) ?? []
        DeletedEntries = try known.decodeIfPresent([DeletedClipEntry].self, forKey: .DeletedEntries) ?? []

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
        for (key, value) in unknownFields {
            try dynamic.encode(value, forKey: DynamicCodingKey(key))
        }
        try dynamic.encode(Version, forKey: DynamicCodingKey("Version"))
        try dynamic.encode(UpdatedUnixMs, forKey: DynamicCodingKey("UpdatedUnixMs"))
        try dynamic.encode(Entries, forKey: DynamicCodingKey("Entries"))
        try dynamic.encode(DeletedEntries, forKey: DynamicCodingKey("DeletedEntries"))
    }
}

public struct SecretEntry: Codable, Identifiable, Equatable, Sendable {
    public var Id: String
    public var Name: String
    public var Value: String
    public var Hotkey: String
    public var CreatedUnixMs: Int64
    public var UpdatedUnixMs: Int64

    public var id: String { Id }

    public init(
        Id: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
        Name: String = "",
        Value: String = "",
        Hotkey: String = "",
        CreatedUnixMs: Int64 = TimeUtil.nowUnixMs(),
        UpdatedUnixMs: Int64 = TimeUtil.nowUnixMs()
    ) {
        self.Id = Id
        self.Name = Name
        self.Value = Value
        self.Hotkey = Hotkey
        self.CreatedUnixMs = CreatedUnixMs
        self.UpdatedUnixMs = UpdatedUnixMs
    }
}

public struct SecretDatabase: Codable, Equatable, Sendable {
    public var Version: Int
    public var UpdatedUnixMs: Int64
    public var Entries: [SecretEntry]

    public init(
        Version: Int = 1,
        UpdatedUnixMs: Int64 = TimeUtil.nowUnixMs(),
        Entries: [SecretEntry] = []
    ) {
        self.Version = Version
        self.UpdatedUnixMs = UpdatedUnixMs
        self.Entries = Entries
    }
}

public struct DeletedClipEntry: Codable, Equatable, Sendable {
    public var Id: String
    public var TextHash: String
    public var DeletedUnixMs: Int64
    public var SourceMachine: String

    public init(Id: String = "", TextHash: String = "", DeletedUnixMs: Int64 = TimeUtil.nowUnixMs(), SourceMachine: String = "") {
        self.Id = Id
        self.TextHash = TextHash
        self.DeletedUnixMs = DeletedUnixMs
        self.SourceMachine = SourceMachine
    }

    private enum CodingKeys: String, CodingKey {
        case Id, TextHash, DeletedUnixMs, SourceMachine
    }

    public init(from decoder: Decoder) throws {
        let known = try decoder.container(keyedBy: CodingKeys.self)
        Id = try known.decodeIfPresent(String.self, forKey: .Id) ?? ""
        TextHash = try known.decodeIfPresent(String.self, forKey: .TextHash) ?? ""
        DeletedUnixMs = try known.decodeIfPresent(Int64.self, forKey: .DeletedUnixMs) ?? TimeUtil.nowUnixMs()
        SourceMachine = try known.decodeIfPresent(String.self, forKey: .SourceMachine) ?? ""
    }
}

public enum TimeUtil {
    public static func nowUnixMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
