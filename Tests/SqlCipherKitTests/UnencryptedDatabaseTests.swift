import Foundation
import Testing

@testable import SqlCipherKit

private struct Item: Entity, Equatable {
    static let tableName = TableName("items")
    static let primaryKey = \Item.id
    var id: Int?
    var name: String
}

@Suite("Unencrypted databases")
struct UnencryptedDatabaseTests {

    @Test("Writes a plain SQLite file readable as plaintext")
    func writesPlaintext() async throws {
        let path = tempDBPath()
        let sentinel = "SQLCIPHERKIT_PLAINTEXT_SENTINEL_9c2b"
        do {
            let db = try Database(unencryptedPath: path, journalMode: .rollback)
            #expect(!db.isEncrypted)
            try await db.execute("CREATE TABLE t (v TEXT)")
            try await db.execute("INSERT INTO t VALUES (?)", sentinel)
        }
        let raw = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(raw.prefix(16) == Data("SQLite format 3\0".utf8))
        #expect(raw.range(of: Data(sentinel.utf8)) != nil)
    }

    @Test("Reopens an unencrypted database")
    func reopens() async throws {
        let path = tempDBPath()
        do {
            let db = try Database(unencryptedPath: path)
            try await db.execute("CREATE TABLE t (v INTEGER)")
            try await db.execute("INSERT INTO t VALUES (5)")
        }
        let db = try Database(unencryptedPath: path)
        let actual1 = try await db.scalarQuery("SELECT v FROM t", as: Int.self)
        #expect(actual1 == 5)
    }

    @Test("Refuses to open an encrypted file as unencrypted")
    func rejectsEncryptedFile() async throws {
        let path = tempDBPath()
        do {
            let db = try Database(path: path, key: "secret")
            try await db.execute("CREATE TABLE t (v INTEGER)")
        }
        #expect {
            _ = try Database(unencryptedPath: path)
        } throws: { error in
            guard case SqlCipherError.notPlaintextDatabase = error else { return false }
            return true
        }
    }

    @Test("Refuses to open an unencrypted file with a key")
    func rejectsKeyOnPlaintextFile() async throws {
        let path = tempDBPath()
        do {
            let db = try Database(unencryptedPath: path)
            try await db.execute("CREATE TABLE t (v INTEGER)")
        }
        #expect(throws: SqlCipherError.self) { _ = try Database(path: path, key: "secret") }
        #expect(throws: SqlCipherError.self) {
            _ = try Database(path: path, rawKey: Data(repeating: 1, count: 32))
        }
    }

    @Test("Rekey is unavailable")
    func rekeyThrows() async throws {
        let db = try Database(unencryptedPath: tempDBPath())
        await #expect {
            try await db.rekey("secret")
        } throws: { error in
            guard case SqlCipherError.notEncrypted = error else { return false }
            return true
        }
        await #expect(throws: SqlCipherError.self) {
            try await db.rekey(rawKey: Data(repeating: 1, count: 32))
        }
    }

    @Test("Entities and transactions work as on an encrypted database")
    func entitiesWork() async throws {
        let db = try Database(unencryptedPath: tempDBPath())
        try await db.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
        let saved = try await db.transaction { conn in
            try conn.save([Item(id: nil, name: "a"), Item(id: nil, name: "b")])
        }
        #expect(saved.map(\.id) == [1, 2])
        let actual2 = try await db.fetch(Item.self).count
        #expect(actual2 == 2)
    }
}
