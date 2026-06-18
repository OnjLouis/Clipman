import Foundation
import ClipmanCore

@discardableResult
func expect(_ condition: @autoclosure () -> Bool, _ message: String) -> Bool {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
    return true
}

func tempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ClipmanSyncSmoke-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

do {
    let dir = try tempDirectory()
    let canonical = dir.appendingPathComponent("clipman-history.clipdb")
    let password = "sync-smoke-password"
    let initial = ClipDatabase(Entries: [
        ClipEntry(Id: "one", Text: "first", SourceMachine: "Mac", CreatedUnixMs: 1, LastUsedUnixMs: 1, ManualOrder: 1)
    ])
    try ClipDatabaseFile.saveAtomic(canonical, database: initial, password: password)

    let external = ClipDatabase(Entries: [
        ClipEntry(Id: "two", Text: "from windows", SourceMachine: "Windows", CreatedUnixMs: 2, LastUsedUnixMs: 2, ManualOrder: 2)
    ])
    try ClipDatabaseFile.saveAtomic(canonical, database: external, password: password)
    let loaded = try ClipDatabaseFile.load(canonical, password: password)
    expect(loaded.Entries.contains(where: { $0.Id == "two" }), "atomic replacement should be readable")

    let conflict = dir.appendingPathComponent("clipman-history (Andre conflicted copy).clipdb")
    let conflictDB = ClipDatabase(Entries: [
        ClipEntry(Id: "three", Text: "conflict entry", SourceMachine: "Other", CreatedUnixMs: 3, LastUsedUnixMs: 3, ManualOrder: 3)
    ])
    try ClipDatabaseFile.saveAtomic(conflict, database: conflictDB, password: password)
    let merged = try SyncConflictResolver.resolveDatabaseConflicts(databaseURL: canonical, password: password)
    expect(merged, "conflict resolver should detect conflict sibling")
    let afterMerge = try ClipDatabaseFile.load(canonical, password: password)
    expect(afterMerge.Entries.contains(where: { $0.Id == "two" }), "canonical entry should survive merge")
    expect(afterMerge.Entries.contains(where: { $0.Id == "three" }), "conflict entry should be merged")
    expect(!FileManager.default.fileExists(atPath: conflict.path), "conflict file should be removed after merge")

    print("Clipman sync smoke tests passed.")
} catch {
    fputs("FAIL: \(error.localizedDescription)\n", stderr)
    exit(1)
}
