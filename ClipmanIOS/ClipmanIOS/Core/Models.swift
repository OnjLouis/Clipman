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

    var id: String { Id }

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
        ManualOrder: Int64 = 0
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
