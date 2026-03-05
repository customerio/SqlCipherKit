import Foundation
import Testing

@testable import SqlCipherKit

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
