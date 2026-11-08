import Foundation
import Testing

@testable import SqlCipherKit

private func rawKey(_ seed: UInt8) -> Data {
    Data((0..<32).map { UInt8($0) &+ seed })
}

@Suite("Raw keys and key validation")
struct KeyModeTests {

    @Test("A raw-key database round-trips across opens")
    func rawKeyRoundTrip() async throws {
        let path = tempDBPath()
        do {
            let db = try Database(path: path, rawKey: rawKey(1))
            try await db.execute("CREATE TABLE t (v TEXT)")
            try await db.execute("INSERT INTO t VALUES (?)", "hello")
        }
        let db = try Database(path: path, rawKey: rawKey(1))
        let v = try await db.scalarQuery("SELECT v FROM t", as: String.self)
        #expect(v == "hello")
        #expect(db.isEncrypted)
    }

    @Test("A raw-key database is encrypted on disk")
    func rawKeyEncryptsFile() async throws {
        let path = tempDBPath()
        let sentinel = "SQLCIPHERKIT_RAWKEY_SENTINEL_4d1e"
        do {
            let db = try Database(path: path, rawKey: rawKey(2), journalMode: .rollback)
            try await db.execute("CREATE TABLE t (v TEXT)")
            try await db.execute("INSERT INTO t VALUES (?)", sentinel)
        }
        let raw = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(raw.range(of: Data(sentinel.utf8)) == nil)
        #expect(raw.prefix(16) != Data("SQLite format 3\0".utf8))
    }

    @Test("Rejects the wrong raw key")
    func rejectsWrongRawKey() async throws {
        let path = tempDBPath()
        do {
            let db = try Database(path: path, rawKey: rawKey(3))
            try await db.execute("CREATE TABLE t (v INTEGER)")
        }
        #expect(throws: SqlCipherError.self) {
            _ = try Database(path: path, rawKey: rawKey(4))
        }
    }

    @Test("A raw-key database does not open with a passphrase, nor the reverse")
    func keyKindsAreNotInterchangeable() async throws {
        let rawPath = tempDBPath()
        do {
            let db = try Database(path: rawPath, rawKey: rawKey(5))
            try await db.execute("CREATE TABLE t (v INTEGER)")
        }
        let hex = rawKey(5).map { String(format: "%02x", $0) }.joined()
        #expect(throws: SqlCipherError.self) {
            _ = try Database(path: rawPath, key: hex)
        }

        let passPath = tempDBPath()
        do {
            let db = try Database(path: passPath, key: "passphrase")
            try await db.execute("CREATE TABLE t (v INTEGER)")
        }
        #expect(throws: SqlCipherError.self) {
            _ = try Database(path: passPath, rawKey: rawKey(5))
        }
    }

    @Test("Rejects a raw key of the wrong length before touching the file", arguments: [0, 16, 31, 33, 64])
    func rejectsWrongLength(length: Int) throws {
        let path = tempDBPath()
        #expect {
            _ = try Database(path: path, rawKey: Data(repeating: 7, count: length))
        } throws: { error in
            guard case SqlCipherError.invalidKey = error else { return false }
            return true
        }
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("Rejects an empty passphrase before touching the file")
    func rejectsEmptyPassphrase() throws {
        let path = tempDBPath()
        #expect {
            _ = try Database(path: path, key: "")
        } throws: { error in
            guard case SqlCipherError.invalidKey = error else { return false }
            return true
        }
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("Rekeys from a passphrase to a raw key and back")
    func rekeyBetweenKinds() async throws {
        let path = tempDBPath()
        do {
            let db = try Database(path: path, key: "old")
            try await db.execute("CREATE TABLE t (v INTEGER)")
            try await db.execute("INSERT INTO t VALUES (1)")
            try await db.rekey(rawKey: rawKey(6))
        }
        #expect(throws: SqlCipherError.self) { _ = try Database(path: path, key: "old") }
        do {
            let db = try Database(path: path, rawKey: rawKey(6))
            let actual1 = try await db.scalarQuery("SELECT v FROM t", as: Int.self)
            #expect(actual1 == 1)
            try await db.rekey("new")
        }
        #expect(throws: SqlCipherError.self) { _ = try Database(path: path, rawKey: rawKey(6)) }
        let db = try Database(path: path, key: "new")
        let actual2 = try await db.scalarQuery("SELECT v FROM t", as: Int.self)
        #expect(actual2 == 1)
    }

    @Test("Rekey rejects invalid keys")
    func rekeyRejectsInvalidKeys() async throws {
        let db = try Database(path: tempDBPath(), key: "k")
        await #expect(throws: SqlCipherError.self) { try await db.rekey("") }
        await #expect(throws: SqlCipherError.self) {
            try await db.rekey(rawKey: Data(repeating: 1, count: 16))
        }
    }
}
