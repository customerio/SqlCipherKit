import Foundation
import Testing

@testable import SqlCipherKit

@Suite("Journal mode")
struct JournalModeTests {

    private func fileMode(_ db: Database) async throws -> String? {
        try await db.scalarQuery("PRAGMA journal_mode", as: String.self)
    }

    @Test("New databases default to WAL", arguments: [false, true])
    func defaultsToWAL(unencrypted: Bool) async throws {
        let path = tempDBPath()
        let db = try unencrypted
            ? Database(unencryptedPath: path)
            : Database(path: path, key: "k")
        #expect(db.journalMode == .wal)
        let actual1 = try await fileMode(db)
        #expect(actual1 == "wal")
    }

    @Test("Creates rollback-journal databases on request", arguments: [false, true])
    func createsRollback(unencrypted: Bool) async throws {
        let path = tempDBPath()
        let db = try unencrypted
            ? Database(unencryptedPath: path, journalMode: .rollback)
            : Database(path: path, key: "k", journalMode: .rollback)
        #expect(db.journalMode == .rollback)
        let actual2 = try await fileMode(db)
        #expect(actual2 == "delete")

        try await db.execute("CREATE TABLE t (v INTEGER)")
        try await db.execute("INSERT INTO t VALUES (1)")
        #expect(!FileManager.default.fileExists(atPath: path + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: path + "-journal"))
    }

    @Test("An existing rollback database stays in rollback mode")
    func keepsRollbackOnOpen() async throws {
        let path = tempDBPath()
        do {
            let db = try Database(path: path, key: "k", journalMode: .rollback)
            try await db.execute("CREATE TABLE t (v INTEGER)")
        }
        let db = try Database(path: path, key: "k")  // requests the default, .wal
        #expect(db.journalMode == .rollback)
        let actual3 = try await fileMode(db)
        #expect(actual3 == "delete")
    }

    @Test("An existing WAL database stays in WAL mode")
    func keepsWALOnOpen() async throws {
        let path = tempDBPath()
        do {
            let db = try Database(path: path, key: "k")
            try await db.execute("CREATE TABLE t (v INTEGER)")
        }
        let db = try Database(path: path, key: "k", journalMode: .rollback)
        #expect(db.journalMode == .wal)
        let actual4 = try await fileMode(db)
        #expect(actual4 == "wal")
    }

    @Test("Raw-key databases honour the requested journal mode")
    func rawKeyJournalMode() async throws {
        let db = try Database(
            path: tempDBPath(), rawKey: Data(repeating: 9, count: 32), journalMode: .rollback)
        #expect(db.journalMode == .rollback)
        let actual5 = try await fileMode(db)
        #expect(actual5 == "delete")
    }

    @Test("In-memory databases open and report rollback", arguments: [JournalMode.wal, .rollback])
    func inMemory(requested: JournalMode) async throws {
        let db = try Database(path: ":memory:", key: "k", journalMode: requested)
        #expect(db.journalMode == .rollback)
        try await db.execute("CREATE TABLE t (v INTEGER)")
        try await db.execute("INSERT INTO t VALUES (1)")
        let count = try await db.scalarQuery("SELECT COUNT(*) FROM t", as: Int.self)
        #expect(count == 1)
    }
}
