import Foundation

enum ServerAppReplacement {
    static func validateCompatibility(of source: URL,
                                      systemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) throws {
        let data = try Data(contentsOf: source.appendingPathComponent("Contents/Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == "com.andrelouis.clipman-server",
              let minimum = info["LSMinimumSystemVersion"] as? String else {
            throw NSError(domain: "ClipmanServerUpdate", code: 4, userInfo: [NSLocalizedDescriptionKey:
                "The server update has missing or invalid Mac compatibility information. The installed app has not been changed."])
        }
        let components = minimum.split(separator: ".", omittingEmptySubsequences: false)
        let parts = components.compactMap { Int($0) }
        guard (1...3).contains(components.count), parts.count == components.count,
              components.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              parts[0] > 0 else {
            throw NSError(domain: "ClipmanServerUpdate", code: 4, userInfo: [NSLocalizedDescriptionKey:
                "The server update has an invalid minimum macOS version. The installed app has not been changed."])
        }
        let required = parts + Array(repeating: 0, count: 3 - parts.count)
        let current = [systemVersion.majorVersion, systemVersion.minorVersion, systemVersion.patchVersion]
        guard !current.lexicographicallyPrecedes(required) else {
            throw NSError(domain: "ClipmanServerUpdate", code: 4, userInfo: [NSLocalizedDescriptionKey:
                "This server update requires macOS \(minimum). This Mac has macOS \(current.map(String.init).joined(separator: ".")). The installed app has not been changed."])
        }
    }

    static func replace(source: URL, destination: URL,
                        move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }) throws {
        try validateCompatibility(of: source)
        let manager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        let identifier = UUID().uuidString
        let staged = parent.appendingPathComponent(".clipman-server-update-\(identifier).app")
        let backup = parent.appendingPathComponent(".clipman-server-rollback-\(identifier).app")
        defer { try? manager.removeItem(at: staged) }
        try manager.copyItem(at: source, to: staged)
        try move(destination, backup)
        do {
            try move(staged, destination)
        } catch {
            // Keep the backup if restoration itself fails, rather than losing it.
            try manager.moveItem(at: backup, to: destination)
            throw error
        }
        try? manager.removeItem(at: backup)
    }
}
