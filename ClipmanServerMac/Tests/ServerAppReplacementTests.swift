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
        try Data("old".utf8).write(to: old)
        try Data("new".utf8).write(to: new)
        var moves = 0
        do {
            try ServerAppReplacement.replace(source: new, destination: old) { source, destination in
                moves += 1
                if moves == 2 { throw NSError(domain: "SyntheticFault", code: 1) }
                try manager.moveItem(at: source, to: destination)
            }
            fatalError("Fault injection did not stop replacement")
        } catch { }
        guard try Data(contentsOf: old) == Data("old".utf8) else { fatalError("Rollback lost original") }
        try ServerAppReplacement.replace(source: new, destination: old)
        guard try Data(contentsOf: old) == Data("new".utf8),
              try manager.contentsOfDirectory(atPath: root.path).sorted() == ["installed.app", "new.app"] else {
            fatalError("Replacement or staging cleanup failed")
        }
        print("Mac replacement, forced failure, rollback and cleanup: PASS")
    }
}
