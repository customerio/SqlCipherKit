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
///
/// Convenience overloads are provided in focused extension files:
/// - Raw SQL: `Database+RawSQL.swift`
/// - QueryBuilder (`Select`, `Insert`, `Update`, `BuiltQuery`): `Database+QueryBuilder.swift`
/// - Codable decoding: `Database+Codable.swift`
/// - Migrations: `Database+Migrations.swift`
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

    // MARK: - Entity configuration

    /// Strategy used to encode and decode complex Swift properties —
    /// arrays, dictionaries, and nested `Codable` structs — that cannot be
    /// stored as a single scalar SQL value.
    ///
    /// Defaults to ``ComplexColumnStrategy/json``, which stores them as UTF-8
    /// JSON text.  Pass `nil` at initialisation to make the encoder throw
    /// loudly when it encounters an unencodable property, which can help
    /// surface schema bugs early in development.
    public let complexColumnStrategy: ComplexColumnStrategy?

    // MARK: - Initialisation

    /// Opens or creates an encrypted database at `path`.
    ///
    /// - Parameters:
    ///   - path:                  Filesystem path for the database file.
    ///   - key:                   Passphrase passed through PBKDF2-HMAC-SHA512 (SqlCipher default).
    ///   - walMode:               When `true` (the default), sets `PRAGMA journal_mode=WAL`
    ///                            immediately after opening.  WAL provides better read/write
    ///                            concurrency and faster writes than the default rollback
    ///                            journal.  The setting is stored in the database file, so it
    ///                            only needs to be applied once per database; subsequent opens
    ///                            can pass `false` if preferred.
    ///   - complexColumnStrategy: How to encode and decode properties that cannot be stored
    ///                            as a scalar SQL value (arrays, dicts, nested structs).
    ///                            Defaults to ``ComplexColumnStrategy/json``.  Pass `nil` to
    ///                            throw an error when such a property is encountered.
    ///
    /// - Throws: ``SqlCipherError/openFailed(message:)`` when the file cannot
    ///   be opened, or ``SqlCipherError/keyFailed(code:)`` when the key is
    ///   rejected (wrong key for an existing database).
    public init(
        path: String,
        key: String,
        walMode: Bool = true,
        complexColumnStrategy: ComplexColumnStrategy? = .json
    ) throws {
        self.complexColumnStrategy = complexColumnStrategy
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
