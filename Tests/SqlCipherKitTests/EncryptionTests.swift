import Foundation
import Testing

@testable import SqlCipherKit

@Suite("Encryption – on-disk ciphertext")
struct EncryptionTests {

    /// A string distinctive enough that it would never appear in SQLite
    /// page headers, B-tree structures, or free-list pages by coincidence.
    private let sentinel = "SQLCIPHERKIT_SENTINEL_7f3a9b2c"

    @Test("Written values are not readable as plaintext in the raw database file")
    func writtenValuesAreEncrypted() async throws {
        let path = tempDBPath()

        // Write the sentinel value and let the Database deallocate, which
        // calls sqlite3_close_v2, flushes all pages, and checkpoints the WAL
        // back into the main file before returning.
        do {
            let db = try Database(path: path, key: "testkey")
            try await db.execute("CREATE TABLE secrets (value TEXT NOT NULL)")
            try await db.execute("INSERT INTO secrets VALUES (?)", sentinel)
        }  // `db` deallocates here — file is fully written and closed.

        let raw = try Data(contentsOf: URL(fileURLWithPath: path))

        // The sentinel string must not appear anywhere in the raw bytes.
        let sentinelData = Data(sentinel.utf8)
        #expect(
            raw.range(of: sentinelData) == nil,
            "Plaintext sentinel found in database file — encryption may not be active.")
    }

    @Test("Database file does not begin with the SQLite plaintext magic header")
    func fileHeaderIsNotPlaintext() async throws {
        let path = tempDBPath()

        do {
            let db = try Database(path: path, key: "testkey")
            try await db.execute("CREATE TABLE t (x INTEGER)")
            try await db.execute("INSERT INTO t VALUES (42)")
        }

        let raw = try Data(contentsOf: URL(fileURLWithPath: path))

        // Every unencrypted SQLite file starts with this 16-byte magic string.
        // An encrypted SQLCipher file starts with random ciphertext instead.
        let sqliteMagic = Data("SQLite format 3\0".utf8)
        let fileHeader = raw.prefix(sqliteMagic.count)
        #expect(
            fileHeader != sqliteMagic,
            "Database file begins with the SQLite plaintext magic header — file is not encrypted.")
    }
}
