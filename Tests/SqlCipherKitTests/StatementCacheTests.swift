import Foundation
import Testing

@testable import SqlCipherKit

@Suite("Statement Cache")
struct StatementCacheTests {

    @Test("Repeated cacheable statements produce correct results")
    func repeatedCacheableQuery() async throws {
        let db = try Database(path: tempDBPath(), key: "k")
        try await db.execute("CREATE TABLE nums (v INTEGER)")
        // Run the same INSERT multiple times — each reuse must correctly reset
        // the cached statement's bindings before applying the new ones.
        for i in 1...5 {
            try await db.execute("INSERT INTO nums VALUES (?)", i)
        }
        let count = try await db.scalarQuery("SELECT COUNT(*) FROM nums", as: Int.self)
        #expect(count == 5)
        let sum = try await db.scalarQuery("SELECT SUM(v) FROM nums", as: Int.self)
        #expect(sum == 15)
    }

    @Test("Cached SELECT with different bindings returns correct rows each time")
    func cacheBindingReset() async throws {
        let db = try Database(path: tempDBPath(), key: "k")
        try await db.execute("CREATE TABLE words (id INTEGER, word TEXT)")
        try await db.execute("INSERT INTO words VALUES (1, 'alpha')")
        try await db.execute("INSERT INTO words VALUES (2, 'beta')")
        try await db.execute("INSERT INTO words VALUES (3, 'gamma')")

        // The same SQL is used 3 times; bindings must differ on each call.
        let sql = "SELECT word FROM words WHERE id = ?"
        let r1 = try await db.scalarQuery(sql, 1, as: String.self)
        let r2 = try await db.scalarQuery(sql, 2, as: String.self)
        let r3 = try await db.scalarQuery(sql, 3, as: String.self)
        #expect(r1 == "alpha")
        #expect(r2 == "beta")
        #expect(r3 == "gamma")
    }

    @Test("DDL statements (CREATE, ALTER, DROP) are not cached and still execute correctly")
    func ddlNotCached() async throws {
        let db = try Database(path: tempDBPath(), key: "k")
        // These must execute successfully even though they bypass the cache.
        try await db.execute("CREATE TABLE t (id INTEGER, name TEXT)")
        try await db.execute("ALTER TABLE t ADD COLUMN score REAL")
        try await db.execute("INSERT INTO t VALUES (1, 'alice', 9.5)")
        let score = try await db.scalarQuery("SELECT score FROM t WHERE id = 1", as: Double.self)
        #expect(score == 9.5)
        try await db.execute("DROP TABLE t")
        // After DROP, querying the table should fail with an error.
        do {
            _ = try await db.query("SELECT * FROM t")
            Issue.record("Expected an error querying a dropped table")
        } catch is SqlCipherError {
            // expected
        }
    }

    @Test("PRAGMA statements are not cached and still execute correctly")
    func pragmaNotCached() async throws {
        // Open without WAL so we start in delete mode.
        let db = try Database(path: tempDBPath(), key: "k", walMode: false)
        // Running the same PRAGMA multiple times must always return fresh results.
        let m1 = try await db.scalarQuery("PRAGMA journal_mode", as: String.self)
        let m2 = try await db.scalarQuery("PRAGMA journal_mode", as: String.self)
        #expect(m1 == "delete")
        #expect(m2 == "delete")
    }
}
