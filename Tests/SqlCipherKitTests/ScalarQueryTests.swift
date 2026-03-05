import Foundation
import Testing

@testable import SqlCipherKit

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
