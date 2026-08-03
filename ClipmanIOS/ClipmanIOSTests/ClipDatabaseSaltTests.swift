import XCTest
@testable import Clipman

final class ClipDatabaseSaltTests: XCTestCase {
    func testEncryptedRewriteCanPreserveSaltWithoutReusingCiphertext() throws {
        let password = "test-history-password"
        let original = ClipDatabase(Entries: [ClipEntry(Id: "one", Text: "Original")])
        let updated = ClipDatabase(Entries: [ClipEntry(Id: "one", Text: "Updated")])

        let first = try ClipDatabaseFile.save(original, password: password)
        let salt = try XCTUnwrap(ClipDatabaseFile.encryptedSalt(from: first))
        let second = try ClipDatabaseFile.save(updated, password: password, preferredSalt: salt)

        XCTAssertEqual(ClipDatabaseFile.encryptedSalt(from: second), salt)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try ClipDatabaseFile.load(second, password: password), updated)
    }

    func testInvalidPreferredSaltIsReplacedWithRandomSalt() throws {
        let data = try ClipDatabaseFile.save(
            ClipDatabase(Entries: [ClipEntry(Text: "Entry")]),
            password: "test-history-password",
            preferredSalt: [1, 2, 3]
        )

        XCTAssertEqual(ClipDatabaseFile.encryptedSalt(from: data)?.count, 16)
    }
}
