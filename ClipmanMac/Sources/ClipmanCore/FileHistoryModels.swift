import Foundation

public struct FileClipboardEvent: Codable, Identifiable, Equatable, Sendable {
    public var Id: String
    public var CapturedUnixMs: Int64
    public var Source: String
    public var Operation: String
    public var SourceMachine: String
    public var ContainsText: Bool
    public var FileCount: Int
    public var Files: [String]
    public var Formats: [String]
    public var Pinned: Bool
    public var ManualOrder: Int64
    public var unknownFields: [String: JSONValue]

    public var id: String { Id }

    public init(
        Id: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
        CapturedUnixMs: Int64 = TimeUtil.nowUnixMs(),
        Source: String = "",
        Operation: String = "",
        SourceMachine: String = "",
        ContainsText: Bool = false,
        FileCount: Int = 0,
        Files: [String] = [],
        Formats: [String] = [],
        Pinned: Bool = false,
        ManualOrder: Int64 = 0,
        unknownFields: [String: JSONValue] = [:]
    ) {
        self.Id = Id
        self.CapturedUnixMs = CapturedUnixMs
        self.Source = Source
        self.Operation = Operation
        self.SourceMachine = SourceMachine
        self.ContainsText = ContainsText
        self.FileCount = FileCount
        self.Files = Files
        self.Formats = Formats
        self.Pinned = Pinned
        self.ManualOrder = ManualOrder
        self.unknownFields = unknownFields
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case Id, CapturedUnixMs, Source, Operation, SourceMachine, ContainsText, FileCount, Files, Formats, Pinned, ManualOrder
    }

    public init(from decoder: Decoder) throws {
        let known = try decoder.container(keyedBy: CodingKeys.self)
        Id = try known.decodeIfPresent(String.self, forKey: .Id) ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        CapturedUnixMs = try known.decodeIfPresent(Int64.self, forKey: .CapturedUnixMs) ?? TimeUtil.nowUnixMs()
        Source = try known.decodeIfPresent(String.self, forKey: .Source) ?? ""
        Operation = try known.decodeIfPresent(String.self, forKey: .Operation) ?? ""
        SourceMachine = try known.decodeIfPresent(String.self, forKey: .SourceMachine) ?? ""
        ContainsText = try known.decodeIfPresent(Bool.self, forKey: .ContainsText) ?? false
        Files = try known.decodeIfPresent([String].self, forKey: .Files) ?? []
        Formats = try known.decodeIfPresent([String].self, forKey: .Formats) ?? []
        FileCount = try known.decodeIfPresent(Int.self, forKey: .FileCount) ?? Files.count
        Pinned = try known.decodeIfPresent(Bool.self, forKey: .Pinned) ?? false
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
        try dynamic.encode(CapturedUnixMs, forKey: DynamicCodingKey("CapturedUnixMs"))
        try dynamic.encode(Source, forKey: DynamicCodingKey("Source"))
        try dynamic.encode(Operation, forKey: DynamicCodingKey("Operation"))
        try dynamic.encode(SourceMachine, forKey: DynamicCodingKey("SourceMachine"))
        try dynamic.encode(ContainsText, forKey: DynamicCodingKey("ContainsText"))
        try dynamic.encode(FileCount, forKey: DynamicCodingKey("FileCount"))
        try dynamic.encode(Files, forKey: DynamicCodingKey("Files"))
        try dynamic.encode(Formats, forKey: DynamicCodingKey("Formats"))
        try dynamic.encode(Pinned, forKey: DynamicCodingKey("Pinned"))
        try dynamic.encode(ManualOrder, forKey: DynamicCodingKey("ManualOrder"))
    }
}

public struct FileClipboardDatabase: Codable, Equatable, Sendable {
    public var Version: Int
    public var UpdatedUnixMs: Int64
    public var Events: [FileClipboardEvent]
    public var unknownFields: [String: JSONValue]

    public init(Version: Int = 1, UpdatedUnixMs: Int64 = TimeUtil.nowUnixMs(), Events: [FileClipboardEvent] = [], unknownFields: [String: JSONValue] = [:]) {
        self.Version = Version
        self.UpdatedUnixMs = UpdatedUnixMs
        self.Events = Events
        self.unknownFields = unknownFields
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case Version, UpdatedUnixMs, Events
    }

    public init(from decoder: Decoder) throws {
        let known = try decoder.container(keyedBy: CodingKeys.self)
        Version = try known.decodeIfPresent(Int.self, forKey: .Version) ?? 1
        UpdatedUnixMs = try known.decodeIfPresent(Int64.self, forKey: .UpdatedUnixMs) ?? TimeUtil.nowUnixMs()
        Events = try known.decodeIfPresent([FileClipboardEvent].self, forKey: .Events) ?? []

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
        try dynamic.encode(Events, forKey: DynamicCodingKey("Events"))
    }
}
