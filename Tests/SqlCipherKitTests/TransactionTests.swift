import Foundation
import Testing

@testable import SqlCipherKit

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
