import Foundation
import Testing

@testable import SqlCipherKit

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
