import Foundation
import Testing

@testable import SqlCipherKit

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
