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

func temporaryURL(_ name: String) -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ClipmanCodecSmoke-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent(name)
}

do {
    if let livePath = ProcessInfo.processInfo.environment["CLIPMAN_TEST_DB_PATH"] {
        let password = ProcessInfo.processInfo.environment["CLIPMAN_TEST_DB_PASSWORD"] ?? ""
        let url = URL(fileURLWithPath: livePath)
        let database = try ClipDatabaseFile.load(url, password: password)
        print("Live database loaded: \(database.Entries.count) text entries.")
        exit(0)
    }

    let compressedURL = temporaryURL("roundtrip.clipdb")
    let database = ClipDatabase(Entries: [
        ClipEntry(Text: "hello", Name: "Greeting", SourceMachine: "Mac", Pinned: true, ManualOrder: 1)
    ])
    try ClipDatabaseFile.saveAtomic(compressedURL, database: database)
    let compressedBytes = try Data(contentsOf: compressedURL)
    expect(compressedBytes.starts(with: ClipDatabaseFile.compressedMagic), "compressed file should start with CLIPDB1")
    let compressedLoaded = try ClipDatabaseFile.load(compressedURL)
    expect(compressedLoaded.Entries.first?.Text == "hello", "compressed text should round-trip")
    expect(compressedLoaded.Entries.first?.Pinned == true, "pinned state should round-trip")

    let encryptedURL = temporaryURL("encrypted.clipdb")
    try ClipDatabaseFile.saveAtomic(encryptedURL, database: ClipDatabase(Entries: [ClipEntry(Text: "secret")]), password: "right")
    let encryptedBytes = try Data(contentsOf: encryptedURL)
    expect(encryptedBytes.starts(with: ClipDatabaseFile.encryptedMagic), "encrypted file should start with CLIPDB2")
    let encryptedLoaded = try ClipDatabaseFile.load(encryptedURL, password: "right")
    expect(encryptedLoaded.Entries.first?.Text == "secret", "encrypted text should round-trip")
    do {
        _ = try ClipDatabaseFile.load(encryptedURL, password: "wrong")
        expect(false, "wrong encrypted password should fail")
    } catch {
        expect(error as? ClipDatabaseError == .incorrectPassword, "wrong password should report incorrectPassword")
    }

    let unknownURL = temporaryURL("unknown.clipdb")
    let json = """
    {
      "Version": 1,
      "UpdatedUnixMs": 10,
      "FutureDatabaseField": "keep me",
      "Entries": [
        {
          "Id": "abc",
          "Text": "entry",
          "Name": "",
          "Group": "",
          "SourceMachine": "Win",
          "CreatedUnixMs": 1,
          "LastUsedUnixMs": 2,
          "Pinned": false,
          "ManualOrder": 1,
          "FutureEntryField": {"Nested": true}
        }
      ]
    }
    """
    let unknownPayload = ClipDatabaseFile.compressedMagic + (try Gzip.compress(Data(json.utf8)))
    try unknownPayload.write(to: unknownURL)
    var unknownDatabase = try ClipDatabaseFile.load(unknownURL)
    unknownDatabase.Entries[0].LastUsedUnixMs = 3
    try ClipDatabaseFile.saveAtomic(unknownURL, database: unknownDatabase)
    let unknownReloaded = try ClipDatabaseFile.load(unknownURL)
    expect(unknownReloaded.unknownFields["FutureDatabaseField"] == .string("keep me"), "database unknown field should be preserved")
    expect(unknownReloaded.Entries[0].unknownFields["FutureEntryField"] == .object(["Nested": .bool(true)]), "entry unknown field should be preserved")

    print("Clipman codec smoke tests passed.")
} catch {
    fputs("FAIL: \(error.localizedDescription)\n", stderr)
    exit(1)
}
