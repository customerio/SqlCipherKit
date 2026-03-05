// MARK: - Database: Migration support

extension Database {

    /// Applies `migrations` in order, skipping any that have already been applied.
    ///
    /// The first time this method is called on a database it creates a
    /// `_migrations` table to track applied migration IDs.  Subsequent calls
    /// compare the supplied array against that table and only execute the
    /// migrations that haven't been recorded yet.
    ///
    /// Each pending migration is wrapped in its own `BEGIN` / `COMMIT`
    /// transaction.  If ``Migration/up(_:)`` throws, the transaction is rolled
    /// back, the error is re-thrown, and no further migrations are applied.
    ///
    /// - Parameter migrations: An ordered array conforming to ``Migration``.
    ///   Dependent migrations must appear after their prerequisites.
    ///
    /// - Throws: Any error thrown by a migration's `up`, or a
    ///   ``SqlCipherError`` if the tracking table cannot be created or queried.
    ///
    /// ### Example
    /// ```swift
    /// try await db.migrate([CreateUsers(), AddScoreColumn()])
    /// ```
    public func migrate(_ migrations: [any Migration]) throws {
        // 1. Bootstrap: ensure the tracking table exists.
        try execute(
            """
            CREATE TABLE IF NOT EXISTS _migrations (
                id         TEXT NOT NULL PRIMARY KEY,
                applied_at TEXT NOT NULL DEFAULT (datetime('now'))
            )
            """)

        // 2. Load the set of already-applied migration IDs.
        let rows = try query("SELECT id FROM _migrations")
        var applied = Set<String>()
        for row in rows {
            if case .text(let s) = row["id"] { applied.insert(s) }
        }

        // 3. Apply each pending migration inside its own transaction.
        for migration in migrations where !applied.contains(migration.id) {
            try withConnection { conn in
                try conn._execute("BEGIN", bindings: [])
                let ctx = MigrationContext(db: conn.db, cache: conn.cache)
                do {
                    try migration.up(ctx)
                    try conn._execute(
                        "INSERT INTO _migrations (id) VALUES (?)",
                        bindings: [migration.id]
                    )
                    try conn._execute("COMMIT", bindings: [])
                } catch {
                    try? conn._execute("ROLLBACK", bindings: [])
                    throw error
                }
            }
        }
    }

    /// Rolls back applied migrations in reverse order, stopping after
    /// ``Migration/down(_:)`` has been called for the migration whose `id`
    /// matches `targetID`.
    ///
    /// Pass the same ordered migration array you use for ``migrate(_:)``.
    /// The method:
    /// 1. Reads applied migration IDs from `_migrations`, ordered by
    ///    insertion time (most-recent last).
    /// 2. Starting from the most-recently-applied migration, calls `down` in
    ///    reverse until it reaches and processes `targetID`.
    /// 3. Each reversal runs in its own transaction; on failure the
    ///    transaction is rolled back and the error is re-thrown.
    ///
    /// - Parameters:
    ///   - targetID: The `id` of the migration to roll back to (inclusive).
    ///     Every migration applied *after and including* this one will be
    ///     reversed.
    ///   - migrations: The same ordered migration array used with
    ///     ``migrate(_:)``.  Migrations not present in this array are skipped
    ///     (they remain recorded as applied).
    ///
    /// - Throws: ``MigrationError/targetNotFound(_:)`` if `targetID` is not
    ///   in the applied set, or any error thrown by a migration's `down`.
    ///
    /// ### Example
    /// ```swift
    /// // Roll back everything from 003 onwards (inclusive).
    /// try await db.rollback(to: "003-add-score", using: allMigrations)
    /// ```
    public func rollback(to targetID: String, using migrations: [any Migration]) throws {
        // 1. Load applied IDs in insertion order (oldest first).
        let rows = try query("SELECT id FROM _migrations ORDER BY rowid ASC")
        let appliedOrdered = rows.compactMap { row -> String? in
            if case .text(let s) = row["id"] { return s } else { return nil }
        }

        guard appliedOrdered.contains(targetID) else {
            throw MigrationError.targetNotFound(targetID)
        }

        // 2. Collect the IDs to roll back: from the most-recent applied down
        //    to and including targetID.
        guard let targetIndex = appliedOrdered.firstIndex(of: targetID) else {
            throw MigrationError.targetNotFound(targetID)
        }
        let toRollback = Array(appliedOrdered[targetIndex...].reversed())

        // 3. Build a lookup map from the provided migration array.
        let migrationByID = Dictionary(
            migrations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // 4. Roll back each migration inside its own transaction.
        for id in toRollback {
            guard let migration = migrationByID[id] else {
                // Migration present in DB but not in the supplied array — skip.
                continue
            }
            try withConnection { conn in
                try conn._execute("BEGIN", bindings: [])
                let ctx = MigrationContext(db: conn.db, cache: conn.cache)
                do {
                    try migration.down(ctx)
                    try conn._execute(
                        "DELETE FROM _migrations WHERE id = ?",
                        bindings: [migration.id]
                    )
                    try conn._execute("COMMIT", bindings: [])
                } catch {
                    try? conn._execute("ROLLBACK", bindings: [])
                    throw error
                }
            }
        }
    }
}

// MARK: - MigrationError

/// Errors thrown by the migration system.
public enum MigrationError: Error, CustomStringConvertible {
    /// The requested rollback target ID was not found in the applied migrations.
    case targetNotFound(String)

    public var description: String {
        switch self {
        case .targetNotFound(let id):
            return "Migration '\(id)' is not in the set of applied migrations."
        }
    }
}
