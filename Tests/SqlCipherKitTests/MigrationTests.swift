import Foundation
import Testing

@testable import SqlCipherKit

// MARK: - Shared concrete migration types
//
// Each struct lives here in the test file the way real migrations would live
// in their own dedicated files inside an app target.

private struct M_CreateUsers: Migration {
    let id = "001-create-users"
    func up(_ ctx: MigrationContext) throws {
        try ctx.execute(
            CreateTable(TableName("users"))
                .column("id", .integer, .autoIncrement)
                .column("name", .text, .notNull)
                .column("email", .text, .notNull, .unique)
        )
    }
    func down(_ ctx: MigrationContext) throws {
        try ctx.execute("DROP TABLE users")
    }
}

private struct M_AddEmail: Migration {
    let id = "002-add-email"
    func up(_ ctx: MigrationContext) throws {
        try ctx.execute(AlterTable(TableName("users"), addColumn: "email", .text))
    }
    func down(_ ctx: MigrationContext) throws {
        // SQLite doesn't support DROP COLUMN on old versions; record intent only.
        // In a real app you'd recreate the table without the column.
        try ctx.execute("SELECT 1")  // no-op stand-in
    }
}

private struct M_AddScore: Migration {
    let id = "003-add-score"
    func up(_ ctx: MigrationContext) throws {
        try ctx.execute(AlterTable(TableName("users"), addColumn: "score", .real, .default(0.0)))
    }
    func down(_ ctx: MigrationContext) throws {
        try ctx.execute("SELECT 1")  // no-op stand-in
    }
}

private struct M_AddBio: Migration {
    let id = "004-add-bio"
    func up(_ ctx: MigrationContext) throws {
        try ctx.execute(AlterTable(TableName("users"), addColumn: "bio", .text))
    }
    func down(_ ctx: MigrationContext) throws {
        try ctx.execute("SELECT 1")  // no-op stand-in
    }
}

private struct M_CreateSettings: Migration {
    let id = "001-create-settings"
    func up(_ ctx: MigrationContext) throws {
        try ctx.execute(
            CreateTable(TableName("settings"))
                .column("key", .text, .primaryKey)
                .column("value", .text, .notNull)
        )
    }
    func down(_ ctx: MigrationContext) throws {
        try ctx.execute("DROP TABLE settings")
    }
}

private struct M_SeedSettings: Migration {
    let id = "002-seed-settings"
    let keyParam = Param<String>("key")
    let valueParam = Param<String>("value")
    func up(_ ctx: MigrationContext) throws {
        let insert = Insert(into: TableName("settings"))
            .set(col("key"), to: keyParam)
            .set(col("value"), to: valueParam)
        try ctx.execute(insert, keyParam.set("theme"), valueParam.set("dark"))
        try ctx.execute(insert, keyParam.set("language"), valueParam.set("en"))
    }
    func down(_ ctx: MigrationContext) throws {
        try ctx.execute("DELETE FROM settings")
    }
}

private struct M_CopyV1ToV2: Migration {
    let id = "001-copy-to-v2"
    func up(_ ctx: MigrationContext) throws {
        try ctx.execute("CREATE TABLE v2 (name TEXT, length INTEGER)")
        let rows = try ctx.query("SELECT name FROM v1")
        for row in rows {
            if case .text(let name) = row["name"] {
                try ctx.execute("INSERT INTO v2 VALUES (?, ?)", name, name.count)
            }
        }
    }
    func down(_ ctx: MigrationContext) throws {
        try ctx.execute("DROP TABLE v2")
    }
}

/// A migration whose `up` can be toggled to fail — uses a class so the flag
/// is shared across @Sendable captures.
private final class M_Transient: Migration, @unchecked Sendable {
    let id = "002-transient"
    var shouldFail: Bool
    init(shouldFail: Bool = true) { self.shouldFail = shouldFail }
    struct TransientError: Error {}
    func up(_ ctx: MigrationContext) throws {
        if shouldFail { throw TransientError() }
    }
    func down(_ ctx: MigrationContext) throws {}
}

/// A migration that counts how many times up() and down() are called.
private final class M_Counted: Migration, @unchecked Sendable {
    let id = "001-counted"
    var upCount = 0
    var downCount = 0
    func up(_ ctx: MigrationContext) throws {
        upCount += 1
        try ctx.execute(
            CreateTable(TableName("counted"))
                .column("id", .integer, .autoIncrement)
        )
    }
    func down(_ ctx: MigrationContext) throws {
        downCount += 1
        try ctx.execute("DROP TABLE counted")
    }
}

// MARK: - Helpers

private func tempDB(_ label: String = "\(Int.random(in: 1_000_000...9_999_999))") throws -> Database
{
    let path = NSTemporaryDirectory() + "migration_\(label).db"
    return try Database(path: path, key: "migration-test")
}

// MARK: - Migration suite

@Suite("Migration")
struct MigrationTests {

    // MARK: Bootstrap

    @Test("migrate creates _migrations table automatically")
    func createsMigrationsTable() async throws {
        let db = try tempDB()
        try await db.migrate([])

        let count = try await db.scalarQuery(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='_migrations'",
            as: Int.self
        )
        #expect(count == 1)
    }

    @Test("migrate with empty array is a no-op")
    func emptyArrayIsNoop() async throws {
        let db = try tempDB()
        try await db.migrate([])
        try await db.migrate([])
    }

    // MARK: Basic application

    @Test("single migration is applied and recorded")
    func singleMigration() async throws {
        let db = try tempDB()

        try await db.migrate([M_CreateUsers()])

        let tableExists = try await db.scalarQuery(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='users'",
            as: Int.self
        )
        #expect(tableExists == 1)

        let rows = try await db.query("SELECT id FROM _migrations")
        #expect(rows.count == 1)
        #expect(rows[0]["id"] == .text("001-create-users"))
    }

    @Test("multiple migrations applied in order")
    func multipleMigrations() async throws {
        let db = try tempDB()
        let users = TableName("users")

        // M_CreateUsers already creates email; M_AddScore and M_AddBio add columns.
        let m1 = M_CreateUsers()
        let m2 = M_AddScore()
        let m3 = M_AddBio()

        try await db.migrate([m1, m2, m3])

        let applied = try await db.query("SELECT id FROM _migrations ORDER BY rowid")
        #expect(applied.count == 3)
        #expect(applied[0]["id"] == .text(m1.id))
        #expect(applied[1]["id"] == .text(m2.id))
        #expect(applied[2]["id"] == .text(m3.id))

        try await db.execute(
            "INSERT INTO users (name, email, score, bio) VALUES ('Alice', 'a@b.com', 9.5, 'hi')"
        )
        let row = try await db.query("SELECT * FROM users").first
        #expect(row?["name"] == .text("Alice"))
        #expect(row?["score"] == .real(9.5))
        #expect(row?["bio"] == .text("hi"))
        _ = users  // silence unused-variable warning
    }

    // MARK: Idempotency

    @Test("already-applied migrations are skipped on second call")
    func secondCallIsIdempotent() async throws {
        let db = try tempDB()
        let m1 = M_Counted()

        try await db.migrate([m1])
        try await db.migrate([m1])  // second call: already applied, skip

        #expect(m1.upCount == 1)
        let count = try await db.scalarQuery("SELECT COUNT(*) FROM _migrations", as: Int.self)
        #expect(count == 1)
    }

    @Test("incremental: new migration added on second call")
    func incrementalMigration() async throws {
        let db = try tempDB()
        let m1 = M_CreateUsers()
        let m2 = M_AddBio()

        try await db.migrate([m1])
        try await db.migrate([m1, m2])  // m1 skipped, m2 applied

        let count = try await db.scalarQuery("SELECT COUNT(*) FROM _migrations", as: Int.self)
        #expect(count == 2)
    }

    // MARK: Rollback on failure

    @Test("failing migration rolls back and is not recorded")
    func failingMigrationRollsBack() async throws {
        let db = try tempDB()
        let m1 = M_CreateUsers()
        let m2 = M_Transient(shouldFail: true)

        var didThrow = false
        do {
            try await db.migrate([m1, m2])
        } catch is M_Transient.TransientError {
            didThrow = true
        }
        #expect(didThrow, "Expected TransientError to propagate")

        let ids = try await db.query("SELECT id FROM _migrations").compactMap {
            if case .text(let s) = $0["id"] { return s } else { return nil }
        }
        #expect(ids == [m1.id])
        #expect(!ids.contains(m2.id))
    }

    @Test("migration can be retried after a prior failure")
    func retryAfterFailure() async throws {
        let db = try tempDB()
        let m1 = M_CreateUsers()
        let m2 = M_Transient(shouldFail: true)

        // First attempt: m2 fails.
        var didThrow = false
        do { try await db.migrate([m1, m2]) } catch is M_Transient.TransientError {
            didThrow = true
        }
        #expect(didThrow)

        // Fix the condition and retry.
        m2.shouldFail = false
        try await db.migrate([m1, m2])

        let count = try await db.scalarQuery("SELECT COUNT(*) FROM _migrations", as: Int.self)
        #expect(count == 2)
    }

    // MARK: MigrationContext API surface

    @Test("Insert and Update builders work inside a migration body")
    func dmlInMigration() async throws {
        let db = try tempDB()

        try await db.migrate([M_CreateSettings(), M_SeedSettings()])

        let rows = try await db.query("SELECT key, value FROM settings ORDER BY key")
        #expect(rows.count == 2)
        #expect(rows[0]["key"] == .text("language"))
        #expect(rows[0]["value"] == .text("en"))
        #expect(rows[1]["key"] == .text("theme"))
        #expect(rows[1]["value"] == .text("dark"))
    }

    @Test("query inside migration body enables data migrations")
    func queryInMigration() async throws {
        let db = try tempDB()
        try await db.execute("CREATE TABLE v1 (name TEXT)")
        try await db.execute("INSERT INTO v1 VALUES ('Alice')")
        try await db.execute("INSERT INTO v1 VALUES ('Bob')")

        try await db.migrate([M_CopyV1ToV2()])

        let rows = try await db.query("SELECT name, length FROM v2 ORDER BY name")
        #expect(rows.count == 2)
        #expect(rows[0]["name"] == .text("Alice"))
        #expect(rows[0]["length"] == .integer(5))
        #expect(rows[1]["name"] == .text("Bob"))
        #expect(rows[1]["length"] == .integer(3))
    }

    @Test("applied_at is recorded as a non-empty text value")
    func appliedAtRecorded() async throws {
        let db = try tempDB()
        try await db.migrate([M_CreateUsers()])

        let rows = try await db.query("SELECT id, applied_at FROM _migrations")
        #expect(rows.count == 1)
        if case .text(let ts) = rows[0]["applied_at"] {
            #expect(!ts.isEmpty)
        } else {
            Issue.record("applied_at should be a non-null TEXT value")
        }
    }

    // MARK: Rollback

    @Test("rollback calls down and removes record")
    func rollbackSingle() async throws {
        let db = try tempDB()
        let m1 = M_Counted()

        try await db.migrate([m1])
        #expect(m1.downCount == 0)

        try await db.rollback(to: m1.id, using: [m1])

        #expect(m1.downCount == 1)
        let count = try await db.scalarQuery("SELECT COUNT(*) FROM _migrations", as: Int.self)
        #expect(count == 0)
        // The table 'counted' should have been dropped.
        let tableExists = try await db.scalarQuery(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='counted'",
            as: Int.self
        )
        #expect(tableExists == 0)
    }

    @Test("rollback to target reverses only migrations at or after target")
    func rollbackToTarget() async throws {
        let db = try tempDB()
        let m1 = M_CreateSettings()
        let m2 = M_SeedSettings()

        try await db.migrate([m1, m2])

        // Roll back only m2 (seed), keep m1 (schema) intact.
        try await db.rollback(to: m2.id, using: [m1, m2])

        let applied = try await db.query("SELECT id FROM _migrations")
        let ids = applied.compactMap { row -> String? in
            if case .text(let s) = row["id"] { return s } else { return nil }
        }
        #expect(ids == [m1.id])
        #expect(!ids.contains(m2.id))

        // Settings table still exists (m1 not rolled back).
        let tableExists = try await db.scalarQuery(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='settings'",
            as: Int.self
        )
        #expect(tableExists == 1)

        // Rows were removed by m2's down().
        let rowCount = try await db.scalarQuery("SELECT COUNT(*) FROM settings", as: Int.self)
        #expect(rowCount == 0)
    }

    @Test("rollback to first migration removes all records")
    func rollbackAll() async throws {
        let db = try tempDB()
        let m1 = M_CreateSettings()
        let m2 = M_SeedSettings()

        try await db.migrate([m1, m2])
        try await db.rollback(to: m1.id, using: [m1, m2])

        let count = try await db.scalarQuery("SELECT COUNT(*) FROM _migrations", as: Int.self)
        #expect(count == 0)
    }

    @Test("rollback then migrate re-applies cleanly")
    func rollbackThenReApply() async throws {
        let db = try tempDB()
        let m1 = M_Counted()

        try await db.migrate([m1])
        try await db.rollback(to: m1.id, using: [m1])
        #expect(m1.upCount == 1)
        #expect(m1.downCount == 1)

        // Re-apply.
        try await db.migrate([m1])
        #expect(m1.upCount == 2)

        let count = try await db.scalarQuery("SELECT COUNT(*) FROM _migrations", as: Int.self)
        #expect(count == 1)
    }

    @Test("rollback throws MigrationError.targetNotFound for unknown ID")
    func rollbackUnknownIDThrows() async throws {
        let db = try tempDB()
        try await db.migrate([M_CreateUsers()])

        var didThrow = false
        do {
            try await db.rollback(to: "does-not-exist", using: [M_CreateUsers()])
        } catch MigrationError.targetNotFound(let id) {
            #expect(id == "does-not-exist")
            didThrow = true
        }
        #expect(didThrow)
    }
}
