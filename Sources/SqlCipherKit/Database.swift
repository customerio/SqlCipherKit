import CSqlCipher
import Foundation

// MARK: - Database

/// A thread-safe, actor-isolated encrypted SQLite database.
///
/// `Database` is the primary entry point for SqlCipherKit.  Obtain one by
/// supplying a file path and an encryption key:
///
/// ```swift
/// let db = try await Database(path: "/path/to/store.db", key: "my-passphrase")
/// ```
///
/// ### Convenience methods (simple statements)
///
/// For straightforward, one-shot operations use the actor's methods directly:
///
/// ```swift
/// try await db.execute("CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY, name TEXT)")
/// try await db.execute("INSERT INTO users VALUES (?, ?)", 1, "Alice")
///
/// let rows  = try await db.query("SELECT * FROM users")
/// let count = try await db.scalarQuery("SELECT COUNT(*) FROM users", as: Int.self)
/// ```
///
/// ### withConnection (multi-statement / transactions)
///
/// Group related statements into a single `withConnection` closure.  The
/// ``Connection`` value passed to the closure is **non-copyable** and
/// **non-escapable**: the compiler guarantees it cannot be stored or returned
/// beyond the call.  All statements execute synchronously on the actor's
/// executor, forming a natural serialisation barrier.
///
/// ```swift
/// let insertedID: Int64? = try await db.withConnection { conn in
///     try conn.execute("BEGIN")
///     try conn.execute("INSERT INTO users VALUES (NULL, ?)", "Bob")
///     let id = try conn.scalarQuery("SELECT last_insert_rowid()", as: Int64.self)
///     try conn.execute("COMMIT")
///     return id
/// }
/// ```
public actor Database {

    // MARK: - Storage

    /// The underlying `sqlite3 *` handle.  Closed in `deinit`.
    ///
    /// Marked `nonisolated(unsafe)` because actor `deinit` is nonisolated
    /// (Swift 6 strict concurrency) but by the time `deinit` runs there are
    /// no remaining references, so no concurrent access is possible.
    private nonisolated(unsafe) let handle: OpaquePointer

    /// LRU cache of compiled prepared statements for this database.
    ///
    /// Also `nonisolated(unsafe)` for the same reason as `handle`; the cache
    /// is only ever accessed from within the actor's executor.
    private nonisolated(unsafe) let statementCache: StatementCache

    // MARK: - Initialisation

    /// Opens or creates an encrypted database at `path`.
    ///
    /// - Parameters:
    ///   - path:    Filesystem path for the database file.
    ///   - key:     Passphrase passed through PBKDF2-HMAC-SHA512 (SqlCipher default).
    ///   - walMode: When `true` (the default), sets `PRAGMA journal_mode=WAL`
    ///              immediately after opening.  WAL provides better read/write
    ///              concurrency and faster writes than the default rollback
    ///              journal.  The setting is stored in the database file, so it
    ///              only needs to be applied once per database; subsequent opens
    ///              can pass `false` if preferred.
    ///
    /// - Throws: ``SqlCipherError/openFailed(message:)`` when the file cannot
    ///   be opened, or ``SqlCipherError/keyFailed(code:)`` when the key is
    ///   rejected (wrong key for an existing database).
    public init(path: String, key: String, walMode: Bool = true) throws {
        var db: OpaquePointer?
        let openRC = sqlite3_open(path, &db)
        guard openRC == SQLITE_OK, let opened = db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            throw SqlCipherError.openFailed(message: msg)
        }

        let keyRC = sqlite3_key(opened, key, Int32(key.utf8.count))
        guard keyRC == SQLITE_OK else {
            sqlite3_close(opened)
            throw SqlCipherError.keyFailed(code: keyRC)
        }

        // Eagerly validate the key by reading the first database page.
        // For a new (empty) database this is a no-op that succeeds.
        // For an existing encrypted database a wrong key surfaces here as
        // SQLITE_NOTADB rather than silently allowing the open to complete.
        var validationStmt: OpaquePointer?
        let validationRC = sqlite3_prepare_v2(
            opened, "SELECT count(*) FROM sqlite_master", -1, &validationStmt, nil
        )
        if let s = validationStmt { sqlite3_finalize(s) }
        guard validationRC == SQLITE_OK else {
            sqlite3_close(opened)
            throw SqlCipherError.keyFailed(code: validationRC)
        }

        if walMode {
            // PRAGMA journal_mode returns a row with the resulting mode name.
            // We execute it and discard the result — any failure here is
            // non-fatal (e.g. read-only filesystem), so we don't throw.
            var walStmt: OpaquePointer?
            if sqlite3_prepare_v2(opened, "PRAGMA journal_mode=WAL", -1, &walStmt, nil) == SQLITE_OK
            {
                sqlite3_step(walStmt)
            }
            if let s = walStmt { sqlite3_finalize(s) }
        }

        self.handle = opened
        self.statementCache = StatementCache(db: opened)
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    // MARK: - withConnection

    /// Provides synchronous, scoped access to the raw database connection.
    ///
    /// The ``Connection`` passed to `body` is confined to the closure's
    /// lifetime — it is non-copyable and non-escapable, so the compiler
    /// prevents it from being stored or returned.
    ///
    /// - Parameter body: A non-escaping closure that receives a borrowed
    ///   ``Connection``.  The closure may call any `Connection` method,
    ///   including running transactions.
    /// - Returns: Whatever `body` returns.
    /// - Throws: Any error thrown by `body`.
    @discardableResult
    public func withConnection<R>(
        _ body: (borrowing Connection) throws -> R
    ) throws -> R {
        try body(Connection(db: handle, cache: statementCache))
    }

    // MARK: - Convenience: execute

    /// Executes an SQL statement that produces no result rows (INSERT, UPDATE,
    /// DELETE, CREATE, …).
    ///
    /// - Parameters:
    ///   - sql:      The SQL text, optionally containing `?` placeholders.
    ///   - bindings: Values to bind to each `?` in order.
    public func execute(_ sql: String, _ bindings: any SQLConvertible...) throws {
        try withConnection { try $0._execute(sql, bindings: bindings) }
    }

    // MARK: - Convenience: query

    /// Executes a SELECT and returns all matching rows.
    ///
    /// - Parameters:
    ///   - sql:      The SQL text, optionally containing `?` placeholders.
    ///   - bindings: Values to bind to each `?` in order.
    /// - Returns: An array containing one ``Row`` per result row.
    public func query(_ sql: String, _ bindings: any SQLConvertible...) throws -> [Row] {
        try withConnection { try $0._query(sql, bindings: bindings) }
    }

    // MARK: - Convenience: scalarQuery

    /// Executes a SELECT and returns the first column of the first row as `T`.
    ///
    /// Returns `nil` when the result set is empty or the column holds `NULL`.
    ///
    /// ```swift
    /// let total = try await db.scalarQuery("SELECT SUM(amount) FROM ledger", as: Double.self)
    /// ```
    ///
    /// - Parameters:
    ///   - sql:      A SELECT that returns at least one column.
    ///   - bindings: Values to bind to each `?` in order.
    ///   - type:     The Swift type to decode the first column into.
    public func scalarQuery<T: SQLConvertible>(
        _ sql: String,
        _ bindings: any SQLConvertible...,
        as type: T.Type = T.self
    ) throws -> T? {
        try withConnection { try $0._scalarQuery(sql, bindings: bindings, as: T.self) }
    }

    // MARK: - BuiltQuery overloads

    /// Executes a pre-built query that produces no result rows.
    public func execute(_ query: BuiltQuery) throws {
        try withConnection { try $0._execute(query) }
    }

    /// Executes a pre-built query and returns all matching rows.
    public func query(_ query: BuiltQuery) throws -> [Row] {
        try withConnection { try $0._query(query) }
    }

    /// Executes a pre-built query and returns the first column of the first row.
    public func scalarQuery<T: SQLConvertible>(_ query: BuiltQuery, as type: T.Type = T.self) throws
        -> T?
    {
        try withConnection { try $0._scalarQuery(query, as: T.self) }
    }

    // MARK: - QueryBuilder: execute

    /// Builds and executes a ``Select`` with variadic ``ParamBinding`` values.
    public func execute(_ select: Select, _ params: ParamBinding...) throws {
        let q = select.build(params: params)
        try withConnection { try $0._execute(q) }
    }

    /// Builds and executes a ``Select`` with a bindings dictionary.
    public func execute(_ select: Select, params: [String: any SQLConvertible]) throws {
        let q = select.build(params: params.map { ParamBinding(name: $0.key, value: $0.value) })
        try withConnection { try $0._execute(q) }
    }

    // MARK: - QueryBuilder: query

    /// Builds and queries a ``Select`` with variadic ``ParamBinding`` values.
    public func query(_ select: Select, _ params: ParamBinding...) throws -> [Row] {
        let q = select.build(params: params)
        return try withConnection { try $0._query(q) }
    }

    /// Builds and queries a ``Select`` with a bindings dictionary.
    public func query(_ select: Select, params: [String: any SQLConvertible]) throws -> [Row] {
        let q = select.build(params: params.map { ParamBinding(name: $0.key, value: $0.value) })
        return try withConnection { try $0._query(q) }
    }

    // MARK: - QueryBuilder: scalarQuery

    /// Builds a ``Select`` query and returns its first column as `T`.
    public func scalarQuery<T: SQLConvertible>(
        _ select: Select,
        _ params: ParamBinding...,
        as type: T.Type = T.self
    ) throws -> T? {
        let q = select.build(params: params)
        return try withConnection { try $0._scalarQuery(q, as: T.self) }
    }

    /// Builds a ``Select`` query (dict params) and returns its first column as `T`.
    public func scalarQuery<T: SQLConvertible>(
        _ select: Select,
        params: [String: any SQLConvertible],
        as type: T.Type = T.self
    ) throws -> T? {
        let q = select.build(params: params.map { ParamBinding(name: $0.key, value: $0.value) })
        return try withConnection { try $0._scalarQuery(q, as: T.self) }
    }

    // MARK: - DDL / DML: CreateTable

    /// Builds and executes a ``CreateTable`` statement.
    public func execute(_ create: CreateTable) throws {
        try withConnection { try $0._execute(create.build()) }
    }

    // MARK: - DDL / DML: AlterTable

    /// Builds and executes an ``AlterTable`` statement.
    public func execute(_ alter: AlterTable) throws {
        try withConnection { try $0._execute(alter.build()) }
    }

    // MARK: - DDL / DML: Insert

    /// Builds and executes an ``Insert`` with variadic ``ParamBinding`` values.
    public func execute(_ insert: Insert, _ params: ParamBinding...) throws {
        try withConnection { try $0._execute(insert.build(params: params)) }
    }

    // MARK: - DDL / DML: Update

    /// Builds and executes an ``Update`` with variadic ``ParamBinding`` values.
    public func execute(_ update: Update, _ params: ParamBinding...) throws {
        try withConnection { try $0._execute(update.build(params: params)) }
    }

    // MARK: - Key management

    /// Re-encrypts the database with a new passphrase.
    ///
    /// This operation rewrites every database page, so it may take a moment
    /// on larger databases.
    ///
    /// - Parameter newKey: The replacement passphrase.
    /// - Throws: ``SqlCipherError/keyFailed(code:)`` if the rekey fails.
    public func rekey(_ newKey: String) throws {
        let rc = sqlite3_rekey(handle, newKey, Int32(newKey.utf8.count))
        guard rc == SQLITE_OK else {
            throw SqlCipherError.keyFailed(code: rc)
        }
    }
}

// MARK: - Migration

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
    ///     with a warning (they remain recorded as applied).
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
