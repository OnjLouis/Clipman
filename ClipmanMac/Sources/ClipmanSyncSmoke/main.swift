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

    let conflict = dir.appendingPathComponent("clipman-history (Laptop conflicted copy).clipdb")
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

    var local = ClipDatabase(Entries: [
        ClipEntry(Id: "push-test", Text: "pushed entry", SourceMachine: "Mac", CreatedUnixMs: 100, LastUsedUnixMs: 100, ManualOrder: 1)
    ])
    let remote = ClipDatabase(Entries: [
        ClipEntry(Id: "push-test", Text: "pushed entry", SourceMachine: "Windows", CreatedUnixMs: 200, LastUsedUnixMs: 200, ManualOrder: 1)
    ])
    SyncConflictResolver.merge(into: &local, source: remote)
    expect(local.Entries.first?.CreatedUnixMs == 200, "newer pushed entry timestamp should win merge")
    expect(local.Entries.first?.SourceMachine == "Windows", "newer pushed entry source machine should win merge")

    var locallyUsedAfterPush = ClipDatabase(Entries: [
        ClipEntry(Id: "push-after-use", Text: "same text", SourceMachine: "Mac", CreatedUnixMs: 100, LastUsedUnixMs: 500, ManualOrder: 1)
    ])
    let pushedAfterLocalUse = ClipDatabase(Entries: [
        ClipEntry(Id: "push-after-use", Text: "same text", SourceMachine: "Windows", CreatedUnixMs: 600, LastUsedUnixMs: 200, ManualOrder: 1)
    ])
    SyncConflictResolver.merge(into: &locallyUsedAfterPush, source: pushedAfterLocalUse)
    expect(locallyUsedAfterPush.Entries.first?.CreatedUnixMs == 600, "newer push timestamp should win even when local last-used is newer")
    expect(locallyUsedAfterPush.Entries.first?.SourceMachine == "Windows", "newer push source should win even when local last-used is newer")

    let deletedText = "https://example.com/recreated"
    let deletedHash = SyncConflictResolver.textHash(deletedText)
    let tombstoneTestNow = TimeUtil.nowUnixMs()
    let deletedMarker = DeletedClipEntry(Id: "deleted-original", TextHash: deletedHash, DeletedUnixMs: tombstoneTestNow - 100, SourceMachine: "Windows")
    var staleDuplicate = ClipDatabase(
        Entries: [ClipEntry(Id: "stale-copy", Text: deletedText, CreatedUnixMs: tombstoneTestNow - 200, LastUsedUnixMs: tombstoneTestNow - 200, ManualOrder: 1)],
        DeletedEntries: [deletedMarker]
    )
    SyncConflictResolver.normalize(&staleDuplicate)
    expect(staleDuplicate.Entries.isEmpty, "same-text entry older than deletion should remain deleted")

    var recreated = ClipDatabase(
        Entries: [ClipEntry(Id: "new-copy", Text: deletedText, CreatedUnixMs: tombstoneTestNow, LastUsedUnixMs: tombstoneTestNow, ManualOrder: 1)],
        DeletedEntries: [deletedMarker]
    )
    SyncConflictResolver.normalize(&recreated)
    expect(recreated.Entries.contains(where: { $0.Id == "new-copy" }), "same-text entry recreated after deletion should survive")

    var staleIdentity = ClipDatabase(
        Entries: [ClipEntry(Id: "deleted-original", Text: deletedText, CreatedUnixMs: tombstoneTestNow, LastUsedUnixMs: tombstoneTestNow, ManualOrder: 1)],
        DeletedEntries: [deletedMarker]
    )
    SyncConflictResolver.normalize(&staleIdentity)
    expect(staleIdentity.Entries.isEmpty, "exact deleted entry identity should never be resurrected")

    print("Clipman sync smoke tests passed.")
} catch {
    fputs("FAIL: \(error.localizedDescription)\n", stderr)
    exit(1)
}
