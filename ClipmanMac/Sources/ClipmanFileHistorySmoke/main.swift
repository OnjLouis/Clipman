import Foundation
import ClipmanCore

let temp = FileManager.default.temporaryDirectory
    .appendingPathComponent("ClipmanFileHistorySmoke-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temp) }

let plainURL = temp.appendingPathComponent("Mac-file-history.clipdb")
let encryptedURL = temp.appendingPathComponent("Mac-encrypted-file-history.clipdb")
let event = FileClipboardEvent(
    Source: "Smoke",
    Operation: "Copy",
    SourceMachine: "Mac",
    ContainsText: true,
    FileCount: 1,
    Files: ["/tmp/clipman-file-history-smoke.txt"],
    Formats: ["public.file-url"],
    ManualOrder: 1
)
let database = FileClipboardDatabase(Events: [event])

try ClipDatabaseFile.saveAtomicCodable(plainURL, value: database)
let plain = try ClipDatabaseFile.loadCodable(plainURL, defaultValue: FileClipboardDatabase())
guard plain.Events.count == 1, plain.Events[0].Files == event.Files else {
    throw NSError(domain: "ClipmanFileHistorySmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: "Plain file-history round trip failed."])
}

try ClipDatabaseFile.saveAtomicCodable(encryptedURL, value: database, password: "secret")
do {
    _ = try ClipDatabaseFile.loadCodable(encryptedURL, password: "wrong", defaultValue: FileClipboardDatabase())
    throw NSError(domain: "ClipmanFileHistorySmoke", code: 2, userInfo: [NSLocalizedDescriptionKey: "Wrong password unexpectedly opened file history."])
} catch ClipDatabaseError.incorrectPassword {
}

let encrypted = try ClipDatabaseFile.loadCodable(encryptedURL, password: "secret", defaultValue: FileClipboardDatabase())
guard encrypted.Events.count == 1, encrypted.Events[0].Files == event.Files else {
    throw NSError(domain: "ClipmanFileHistorySmoke", code: 3, userInfo: [NSLocalizedDescriptionKey: "Encrypted file-history round trip failed."])
}

print("Clipman file-history smoke tests passed.")
