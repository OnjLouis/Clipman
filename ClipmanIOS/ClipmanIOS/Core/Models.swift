import Foundation
#if os(iOS)
import UIKit
#endif

struct ClipEntry: Codable, Identifiable, Equatable, Sendable {
    var Id: String
    var Text: String
    var Name: String
    var Group: String
    var SourceMachine: String
    var CreatedUnixMs: Int64
    var LastUsedUnixMs: Int64
    var Pinned: Bool
    var IsTemplate: Bool
    var ManualOrder: Int64
    var RichText: RichTextPayload?
    var RichTextUpdatedUnixMs: Int64

    var id: String { Id }

    private enum CodingKeys: String, CodingKey {
        case Id, Text, Name, Group, SourceMachine, CreatedUnixMs, LastUsedUnixMs
        case Pinned, IsTemplate, ManualOrder, RichText, RichTextUpdatedUnixMs
    }

    init(
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
        RichText: RichTextPayload? = nil,
        RichTextUpdatedUnixMs: Int64 = 0
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
        self.RichText = RichText
        self.RichTextUpdatedUnixMs = RichTextUpdatedUnixMs
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        Id = try values.decodeIfPresent(String.self, forKey: .Id) ?? ""
        Text = try values.decodeIfPresent(String.self, forKey: .Text) ?? ""
        Name = try values.decodeIfPresent(String.self, forKey: .Name) ?? ""
        Group = try values.decodeIfPresent(String.self, forKey: .Group) ?? ""
        SourceMachine = try values.decodeIfPresent(String.self, forKey: .SourceMachine) ?? ""
        CreatedUnixMs = try values.decodeIfPresent(Int64.self, forKey: .CreatedUnixMs) ?? 0
        LastUsedUnixMs = try values.decodeIfPresent(Int64.self, forKey: .LastUsedUnixMs) ?? CreatedUnixMs
        Pinned = try values.decodeIfPresent(Bool.self, forKey: .Pinned) ?? false
        IsTemplate = try values.decodeIfPresent(Bool.self, forKey: .IsTemplate) ?? false
        ManualOrder = try values.decodeIfPresent(Int64.self, forKey: .ManualOrder) ?? 0
        RichText = try values.decodeIfPresent(RichTextPayload.self, forKey: .RichText)
        RichTextUpdatedUnixMs = try values.decodeIfPresent(Int64.self, forKey: .RichTextUpdatedUnixMs) ?? 0
    }
}

struct RichTextPayload: Codable, Equatable, Sendable {
    var Version: Int = 1
    var HtmlFragment: String = ""
    var RtfBase64: String = ""
    var PreferredFormat: String = ""

    private enum CodingKeys: String, CodingKey {
        case Version, HtmlFragment, RtfBase64, PreferredFormat
    }

    init(
        Version: Int = 1,
        HtmlFragment: String = "",
        RtfBase64: String = "",
        PreferredFormat: String = ""
    ) {
        self.Version = Version
        self.HtmlFragment = HtmlFragment
        self.RtfBase64 = RtfBase64
        self.PreferredFormat = PreferredFormat
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        Version = try values.decodeIfPresent(Int.self, forKey: .Version) ?? 1
        HtmlFragment = try values.decodeIfPresent(String.self, forKey: .HtmlFragment) ?? ""
        RtfBase64 = try values.decodeIfPresent(String.self, forKey: .RtfBase64) ?? ""
        PreferredFormat = try values.decodeIfPresent(String.self, forKey: .PreferredFormat) ?? ""
    }
}

struct DeletedClipEntry: Codable, Equatable, Sendable {
    var Id: String
    var TextHash: String
    var DeletedUnixMs: Int64
    var SourceMachine: String
}

struct ClipDatabase: Codable, Equatable, Sendable {
    var Version: Int
    var UpdatedUnixMs: Int64
    var Entries: [ClipEntry]
    var DeletedEntries: [DeletedClipEntry]

    private enum CodingKeys: String, CodingKey {
        case Version, UpdatedUnixMs, Entries, DeletedEntries
    }

    init(
        Version: Int = 1,
        UpdatedUnixMs: Int64 = TimeUtil.nowUnixMs(),
        Entries: [ClipEntry] = [],
        DeletedEntries: [DeletedClipEntry] = []
    ) {
        self.Version = Version
        self.UpdatedUnixMs = UpdatedUnixMs
        self.Entries = Entries
        self.DeletedEntries = DeletedEntries
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        Version = try values.decodeIfPresent(Int.self, forKey: .Version) ?? 1
        UpdatedUnixMs = try values.decodeIfPresent(Int64.self, forKey: .UpdatedUnixMs) ?? 0
        Entries = try values.decodeIfPresent([ClipEntry].self, forKey: .Entries) ?? []
        DeletedEntries = try values.decodeIfPresent([DeletedClipEntry].self, forKey: .DeletedEntries) ?? []
    }
}

enum TimeUtil {
    static func nowUnixMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}

enum UIDeviceMachine {
    @MainActor
    static var name: String {
        #if os(iOS)
        UIDevice.current.name
        #else
        ProcessInfo.processInfo.hostName
        #endif
    }
}
