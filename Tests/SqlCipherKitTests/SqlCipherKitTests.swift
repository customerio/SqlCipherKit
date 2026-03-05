import Foundation
import Testing

@testable import SqlCipherKit

// MARK: - Helper

private func tempDBPath() -> String {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sqlcipherkit-test-\(UUID().uuidString).db")
        .path
}

// MARK: - Database lifecycle

@Suite("Database Lifecycle")
struct DatabaseLifecycleTests {

    @Test("Opens and closes a new encrypted database")
    func opensNewDatabase() async throws {
        let path = tempDBPath()
        let db = try Database(path: path, key: "testkey")
        try await db.execute("SELECT 1")
    }

    @Test("Enables WAL mode by default")
    func walModeDefault() async throws {
        let db = try Database(path: tempDBPath(), key: "testkey")
        let mode = try await db.scalarQuery("PRAGMA journal_mode", as: String.self)
        #expect(mode == "wal")
    }

    @Test("Respects walMode: false")
    func walModeDisabled() async throws {
        let db = try Database(path: tempDBPath(), key: "testkey", walMode: false)
        let mode = try await db.scalarQuery("PRAGMA journal_mode", as: String.self)
        #expect(mode == "delete")
    }

    @Test("Rejects the wrong key for an existing database")
    func rejectsWrongKey() async throws {
        let path = tempDBPath()

        // Create a database with a known key, then let the connection close.
        do {
            let db = try Database(path: path, key: "correct-key")
            try await db.execute("CREATE TABLE t (x INTEGER)")
        }  // `db` deallocates here → sqlite3_close_v2 is called

        // Attempting to open the same file with the wrong key should throw
        // once the eager validation query fires.
        #expect(throws: SqlCipherError.self) {
            _ = try Database(path: path, key: "wrong-key")
        }
    }
}

// MARK: - Execute / Query

@Suite("Execute and Query")
struct ExecuteQueryTests {

    @Test("Inserts and reads back rows")
    func insertAndReadRows() async throws {
        let db = try Database(path: tempDBPath(), key: "k")
        try await db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
        try await db.execute("INSERT INTO users VALUES (?, ?)", 1, "Alice")
        try await db.execute("INSERT INTO users VALUES (?, ?)", 2, "Bob")

        let rows = try await db.query("SELECT id, name FROM users ORDER BY id")
        #expect(rows.count == 2)
        #expect(rows[0].get("name", as: String.self) == "Alice")
        #expect(rows[1].get("name", as: String.self) == "Bob")
    }

    @Test("Returns empty array when no rows match")
    func emptyResultSet() async throws {
        let db = try Database(path: tempDBPath(), key: "k")
        try await db.execute("CREATE TABLE items (v INTEGER)")
        let rows = try await db.query("SELECT * FROM items WHERE v > 100")
        #expect(rows.isEmpty)
    }
}

// MARK: - Scalar query

@Suite("Scalar Query")
struct ScalarQueryTests {

    @Test("Returns count of inserted rows")
    func countRows() async throws {
        let db = try Database(path: tempDBPath(), key: "k")
        try await db.execute("CREATE TABLE t (v INTEGER)")
        try await db.execute("INSERT INTO t VALUES (?)", 10)
        try await db.execute("INSERT INTO t VALUES (?)", 20)

        let count = try await db.scalarQuery("SELECT COUNT(*) FROM t", as: Int.self)
        #expect(count == 2)
    }

    @Test("Returns nil for empty result set")
    func nilOnEmpty() async throws {
        let db = try Database(path: tempDBPath(), key: "k")
        try await db.execute("CREATE TABLE t (v TEXT)")
        let result = try await db.scalarQuery(
            "SELECT v FROM t WHERE v = 'missing'", as: String.self)
        #expect(result == nil)
    }

    @Test("Decodes Integer to various Swift types")
    func decodesInt() async throws {
        let db = try Database(path: tempDBPath(), key: "k")
        let n = try await db.scalarQuery("SELECT 42", as: Int.self)
        #expect(n == 42)
        let n64 = try await db.scalarQuery("SELECT 42", as: Int64.self)
        #expect(n64 == 42)
    }

    @Test("Decodes Real to Double")
    func decodesDouble() async throws {
        let db = try Database(path: tempDBPath(), key: "k")
        let d = try await db.scalarQuery("SELECT 3.14", as: Double.self)
        #expect(d != nil)
        #expect(abs(d! - 3.14) < 0.001)
    }
}

// MARK: - withConnection (transactions)

@Suite("withConnection / Transactions")
struct TransactionTests {

    @Test("Runs a multi-statement transaction")
    func transaction() async throws {
        let db = try Database(path: tempDBPath(), key: "k")
        try await db.execute("CREATE TABLE ledger (amount REAL NOT NULL)")

        let total: Double? = try await db.withConnection { conn in
            try conn.execute("BEGIN")
            try conn.execute("INSERT INTO ledger VALUES (?)", 100.0)
            try conn.execute("INSERT INTO ledger VALUES (?)", 50.0)
            try conn.execute("COMMIT")
            return try conn.scalarQuery("SELECT SUM(amount) FROM ledger", as: Double.self)
        }

        #expect(total == 150.0)
    }

    @Test("Rolls back incomplete transaction on error")
    func rollback() async throws {
        let db = try Database(path: tempDBPath(), key: "k")
        try await db.execute("CREATE TABLE t (v INTEGER NOT NULL)")

        do {
            try await db.withConnection { conn in
                try conn.execute("BEGIN")
                try conn.execute("INSERT INTO t VALUES (?)", 1)
                // Force an error by violating NOT NULL
                try conn.execute("INSERT INTO t VALUES (?)", Value.null)
            }
            Issue.record("Expected an error from NOT NULL constraint")
        } catch {
            // Roll back manually (real usage would handle this in the error path)
            try await db.execute("ROLLBACK")
        }

        let count = try await db.scalarQuery("SELECT COUNT(*) FROM t", as: Int.self)
        #expect(count == 0)
    }
}

// MARK: - Row access

@Suite("Row")
struct RowTests {

    @Test("Subscript by index and name")
    func rowSubscript() async throws {
        let db = try Database(path: tempDBPath(), key: "k")
        try await db.execute("CREATE TABLE t (id INTEGER, label TEXT)")
        try await db.execute("INSERT INTO t VALUES (7, 'hello')")
        let rows = try await db.query("SELECT id, label FROM t")

        let row = try #require(rows.first)
        #expect(row[0] == .integer(7))
        #expect(row[1] == .text("hello"))
        #expect(row["id"] == .integer(7))
        #expect(row["label"] == .text("hello"))
        #expect(row["missing"] == nil)
    }

    @Test("require(_:as:) throws for missing column")
    func requireThrows() async throws {
        let db = try Database(path: tempDBPath(), key: "k")
        try await db.execute("CREATE TABLE t (x INTEGER)")
        try await db.execute("INSERT INTO t VALUES (1)")
        let rows = try await db.query("SELECT x FROM t")
        let row = try #require(rows.first)

        #expect(throws: SqlCipherError.self) {
            _ = try row.require("nonexistent", as: Int.self)
        }
    }
}

// MARK: - Value type conformances

@Suite("SQLConvertible Conformances")
struct ValueConformanceTests {

    @Test("Bool round-trips")
    func boolRoundTrip() async throws {
        let db = try Database(path: tempDBPath(), key: "k")
        try await db.execute("CREATE TABLE flags (active INTEGER)")
        try await db.execute("INSERT INTO flags VALUES (?)", true)
        let v = try await db.scalarQuery("SELECT active FROM flags", as: Bool.self)
        #expect(v == true)
    }

    @Test("Data round-trips")
    func dataRoundTrip() async throws {
        let db = try Database(path: tempDBPath(), key: "k")
        try await db.execute("CREATE TABLE blobs (raw BLOB)")
        let original = Data([0xDE, 0xAD, 0xBE, 0xEF])
        try await db.execute("INSERT INTO blobs VALUES (?)", original)
        let result = try await db.scalarQuery("SELECT raw FROM blobs", as: Data.self)
        #expect(result == original)
    }
}
