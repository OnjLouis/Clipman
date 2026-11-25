import Foundation

@main
struct ServerAppReplacementTests {
    static func main() throws {
        let manager = FileManager.default
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"]!).appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let old = root.appendingPathComponent("installed.app")
        let new = root.appendingPathComponent("new.app")
        try makeApp(at: old, minimum: "13.0", marker: "old")
        try makeApp(at: new, minimum: "13.0", marker: "new")
        var moves = 0
        do {
            try ServerAppReplacement.replace(source: new, destination: old) { source, destination in
                moves += 1
                if moves == 2 { throw NSError(domain: "SyntheticFault", code: 1) }
                try manager.moveItem(at: source, to: destination)
            }
            fatalError("Fault injection did not stop replacement")
        } catch { }
        guard try Data(contentsOf: old.appendingPathComponent("marker")) == Data("old".utf8) else { fatalError("Rollback lost original") }
        try ServerAppReplacement.replace(source: new, destination: old)
        guard try Data(contentsOf: old.appendingPathComponent("marker")) == Data("new".utf8),
              try manager.contentsOfDirectory(atPath: root.path).sorted() == ["installed.app", "new.app"] else {
            fatalError("Replacement or staging cleanup failed")
        }
        print("Mac replacement, forced failure, rollback and cleanup: PASS")

        let future = ProcessInfo.processInfo.operatingSystemVersion.majorVersion + 1
        let incompatible = root.appendingPathComponent("incompatible.app")
        try makeApp(at: incompatible, minimum: "\(future).0", marker: "incompatible")
        var rejected = false
        do {
            try ServerAppReplacement.replace(source: incompatible, destination: old)
        } catch {
            rejected = true
        }
        guard rejected,
              try Data(contentsOf: old.appendingPathComponent("marker")) == Data("new".utf8),
              try manager.contentsOfDirectory(atPath: root.path).sorted() == ["incompatible.app", "installed.app", "new.app"] else {
            fatalError("An incompatible update replaced the working server or left staging behind")
        }
        print("Mac incompatible update preserves the installed server: PASS")

        let macOS26 = OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        try ServerAppReplacement.validateCompatibility(of: new, systemVersion: macOS26)
        for minimum in ["27.0", "26.0.1", "", "26.x", "26..0", "-1", "26.0.0.1"] {
            try manager.removeItem(at: incompatible)
            try makeApp(at: incompatible, minimum: minimum, marker: "incompatible")
            var failed = false
            do {
                try ServerAppReplacement.validateCompatibility(of: incompatible, systemVersion: macOS26)
            } catch {
                failed = true
            }
            guard failed else { fatalError("Unsupported or malformed macOS requirement was accepted: \(minimum)") }
        }
        try manager.removeItem(at: incompatible.appendingPathComponent("Contents/Info.plist"))
        var missingRejected = false
        do {
            try ServerAppReplacement.validateCompatibility(of: incompatible, systemVersion: macOS26)
        } catch { missingRejected = true }
        guard missingRejected else { fatalError("Missing compatibility information was accepted") }
        if let app = ProcessInfo.processInfo.environment["CLIPMAN_SERVER_APP_FIXTURE"] {
            try ServerAppReplacement.validateCompatibility(of: URL(fileURLWithPath: app), systemVersion: macOS26)
        }
        print("Mac OS 26 compatibility, future versions and malformed requirements: PASS")
    }

    static func makeApp(at app: URL, minimum: String, marker: String) throws {
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.andrelouis.clipman-server",
            "LSMinimumSystemVersion": minimum
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try Data(marker.utf8).write(to: app.appendingPathComponent("marker"))
    }
}
