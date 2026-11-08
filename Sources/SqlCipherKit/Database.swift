import CSqlCipher
import Foundation

// MARK: - Database

/// A thread-safe, actor-isolated encrypted SQLite database.
///
/// `Database` is the primary entry point for SqlCipherKit.  Obtain one by
/// supplying a file path and an encryption key:
///
/// ```swift
/// let db = try Database(path: "/path/to/store.db", key: "my-passphrase")
/// ```
///
/// A 32-byte raw key (``init(path:rawKey:journalMode:complexColumnStrategy:)``)
/// skips key derivation, and ``init(unencryptedPath:journalMode:complexColumnStrategy:)``
/// opens a plain SQLite file.  The ``JournalMode`` is chosen when the file is
/// created.
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
/// ### transaction (atomic multi-statement work)
///
/// ``transaction(_:)`` wraps a synchronous body in `BEGIN` / `COMMIT` and
/// rolls back if it throws.  The ``Connection`` it passes supports raw SQL,
/// query builders, and entity operations:
///
/// ```swift
/// try await db.transaction { conn in
///     let order = try conn.save(Order(id: nil, customer: "Alice"))
///     try conn.save(LineItem(id: nil, orderID: order.id!, sku: "A-1"))
/// }
/// ```
///
/// ### withConnection (multi-statement, manual control)
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
/// - Entities and transactions: `Database+Entity.swift` (forwarding to `Connection+Entity.swift`)
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

    // MARK: - Database properties

    /// `false` when the database was opened through
    /// ``init(unencryptedPath:journalMode:complexColumnStrategy:)``; `true` otherwise.
    public nonisolated let isEncrypted: Bool

    /// The journal mode the database file is in.
    ///
    /// For a new database this is the mode requested at initialisation.  For an
    /// existing database it is the mode read from the file, which may differ
    /// from the one requested: the journal mode of an existing file is never
    /// changed.
    public nonisolated let journalMode: JournalMode

    /// The required length, in bytes, of a raw key passed to
    /// ``init(path:rawKey:journalMode:complexColumnStrategy:)`` or ``rekey(rawKey:)``.
    public static let rawKeyLength = 32

    // MARK: - Initialisation

    /// Opens or creates a database at `path`, encrypted with a passphrase.
    ///
    /// The passphrase is run through SQLCipher's key derivation function
    /// (PBKDF2-HMAC-SHA512 by default).  When you already hold uniformly random
    /// key material, use ``init(path:rawKey:journalMode:complexColumnStrategy:)``
    /// instead and skip the derivation cost.
    ///
    /// - Parameters:
    ///   - path:                  Filesystem path for the database file.
    ///   - key:                   The passphrase.  Must not be empty: SQLCipher treats an
    ///                            empty key as "no encryption", so an empty value is rejected
    ///                            rather than silently producing a plaintext file.  Use
    ///                            ``init(unencryptedPath:journalMode:complexColumnStrategy:)``
    ///                            when plaintext is intended.
    ///   - journalMode:           The journal mode for a **new** database.  Defaults to
    ///                            ``JournalMode/wal``.  Ignored when the file already holds a
    ///                            database; the file's own mode is kept and reported by
    ///                            ``journalMode``.
    ///   - complexColumnStrategy: How to encode and decode properties that cannot be stored
    ///                            as a scalar SQL value (arrays, dicts, nested structs).
    ///                            Defaults to ``ComplexColumnStrategy/json``.  Pass `nil` to
    ///                            throw an error when such a property is encountered.
    ///
    /// - Throws: ``SqlCipherError/invalidKey(reason:)`` for an empty passphrase,
    ///   ``SqlCipherError/openFailed(message:)`` when the file cannot be opened,
    ///   ``SqlCipherError/keyFailed(code:)`` when the key is rejected (wrong key,
    ///   wrong kind of key, or an unencrypted file), or a journal-mode error.
    public init(
        path: String,
        key: String,
        journalMode: JournalMode = .wal,
        complexColumnStrategy: ComplexColumnStrategy? = .json
    ) throws {
        guard !key.isEmpty else {
            throw SqlCipherError.invalidKey(reason: "the passphrase is empty")
        }
        try self.init(
            path: path,
            keyMaterial: .passphrase(key),
            journalMode: journalMode,
            complexColumnStrategy: complexColumnStrategy
        )
    }

    /// Opens or creates a database at `path`, encrypted with a 32-byte raw key.
    ///
    /// SQLCipher uses the bytes directly as the page encryption key and skips
    /// its key derivation function, so opening costs no key stretching.  Use
    /// this when the key is already full-entropy material, such as the output
    /// of a KDF you run yourself or a key held in the Keychain.
    ///
    /// A database created with a raw key cannot be opened with a passphrase,
    /// or the reverse, even when the passphrase consists of the same bytes.
    ///
    /// The library does not retain `rawKey`, and does not zero the caller's
    /// `Data`.
    ///
    /// - Parameters:
    ///   - path:                  Filesystem path for the database file.
    ///   - rawKey:                Exactly ``rawKeyLength`` (32) bytes.
    ///   - journalMode:           The journal mode for a **new** database.  See
    ///                            ``init(path:key:journalMode:complexColumnStrategy:)``.
    ///   - complexColumnStrategy: See ``init(path:key:journalMode:complexColumnStrategy:)``.
    ///
    /// - Throws: ``SqlCipherError/invalidKey(reason:)`` when `rawKey` is not
    ///   32 bytes (before the file is touched), plus the errors listed for
    ///   ``init(path:key:journalMode:complexColumnStrategy:)``.
    public init(
        path: String,
        rawKey: Data,
        journalMode: JournalMode = .wal,
        complexColumnStrategy: ComplexColumnStrategy? = .json
    ) throws {
        try Self.validateRawKey(rawKey)
        try self.init(
            path: path,
            keyMaterial: .raw(rawKey),
            journalMode: journalMode,
            complexColumnStrategy: complexColumnStrategy
        )
    }

    /// Opens or creates a plain, **unencrypted** SQLite database at `path`.
    ///
    /// No key is applied: the file is readable by any SQLite tool.  Intended
    /// for data that is public or already ciphertext.  Plaintext is a separate
    /// initialiser rather than an optional key so that it is always an
    /// explicit choice.
    ///
    /// ``isEncrypted`` is `false` and ``rekey(_:)`` throws.  Every query,
    /// entity, and migration API works as it does for an encrypted database.
    ///
    /// - Parameters:
    ///   - path:                  Filesystem path for the database file.
    ///   - journalMode:           The journal mode for a **new** database.  See
    ///                            ``init(path:key:journalMode:complexColumnStrategy:)``.
    ///   - complexColumnStrategy: See ``init(path:key:journalMode:complexColumnStrategy:)``.
    ///
    /// - Throws: ``SqlCipherError/notPlaintextDatabase(code:)`` when the file is
    ///   encrypted or is not a SQLite database,
    ///   ``SqlCipherError/openFailed(message:)`` when it cannot be opened, or a
    ///   journal-mode error.
    public init(
        unencryptedPath path: String,
        journalMode: JournalMode = .wal,
        complexColumnStrategy: ComplexColumnStrategy? = .json
    ) throws {
        try self.init(
            path: path,
            keyMaterial: .none,
            journalMode: journalMode,
            complexColumnStrategy: complexColumnStrategy
        )
    }

    /// Opens or creates an encrypted database at `path`.
    ///
    /// `walMode: true` maps to ``JournalMode/wal`` and `false` to
    /// ``JournalMode/rollback``.  As with the replacement initialiser, the mode
    /// now applies only when the database is created; an existing file keeps
    /// its journal mode.
    @available(
        *, deprecated,
        renamed: "init(path:key:journalMode:complexColumnStrategy:)",
        message: "Pass a JournalMode. The mode applies only when the database is created."
    )
    public init(
        path: String,
        key: String,
        walMode: Bool,
        complexColumnStrategy: ComplexColumnStrategy? = .json
    ) throws {
        try self.init(
            path: path,
            key: key,
            journalMode: walMode ? .wal : .rollback,
            complexColumnStrategy: complexColumnStrategy
        )
    }

    private init(
        path: String,
        keyMaterial: KeyMaterial,
        journalMode requested: JournalMode,
        complexColumnStrategy: ComplexColumnStrategy?
    ) throws {
        var db: OpaquePointer?
        let openRC = sqlite3_open(path, &db)
        guard openRC == SQLITE_OK, let opened = db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            throw SqlCipherError.openFailed(message: msg)
        }

        let mode: JournalMode
        do {
            try Self.applyKey(keyMaterial, to: opened)
            try Self.verifyReadable(opened, encrypted: keyMaterial.isEncrypted)
            mode = try Self.resolveJournalMode(opened, requested: requested)
        } catch {
            sqlite3_close(opened)
            throw error
        }

        self.complexColumnStrategy = complexColumnStrategy
        self.isEncrypted = keyMaterial.isEncrypted
        self.journalMode = mode
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
        try body(
            Connection(
                db: handle, cache: statementCache, complexColumnStrategy: complexColumnStrategy))
    }

    // MARK: - Key management

    /// Re-encrypts the database with a new passphrase.
    ///
    /// This operation rewrites every database page, so it may take a moment
    /// on larger databases.  Either kind of key (passphrase or raw) may
    /// replace either kind.
    ///
    /// - Parameter newKey: The replacement passphrase.  Must not be empty.
    /// - Throws: ``SqlCipherError/notEncrypted`` for an unencrypted database,
    ///   ``SqlCipherError/invalidKey(reason:)`` for an empty passphrase, or
    ///   ``SqlCipherError/keyFailed(code:)`` if the rekey fails.
    public func rekey(_ newKey: String) throws {
        guard isEncrypted else { throw SqlCipherError.notEncrypted }
        guard !newKey.isEmpty else {
            throw SqlCipherError.invalidKey(reason: "the passphrase is empty")
        }
        let rc = sqlite3_rekey(handle, newKey, Int32(newKey.utf8.count))
        guard rc == SQLITE_OK else {
            throw SqlCipherError.keyFailed(code: rc)
        }
    }

    /// Re-encrypts the database with a new 32-byte raw key.
    ///
    /// See ``rekey(_:)`` and ``init(path:rawKey:journalMode:complexColumnStrategy:)``.
    ///
    /// - Parameter rawKey: Exactly ``rawKeyLength`` (32) bytes.
    /// - Throws: ``SqlCipherError/notEncrypted`` for an unencrypted database,
    ///   ``SqlCipherError/invalidKey(reason:)`` for a key of the wrong length,
    ///   or ``SqlCipherError/keyFailed(code:)`` if the rekey fails.
    public func rekey(rawKey: Data) throws {
        guard isEncrypted else { throw SqlCipherError.notEncrypted }
        try Self.validateRawKey(rawKey)
        let rc = Self.withRawKeyLiteral(rawKey) { sqlite3_rekey(handle, $0, $1) }
        guard rc == SQLITE_OK else {
            throw SqlCipherError.keyFailed(code: rc)
        }
    }
}

// MARK: - Opening helpers

extension Database {

    /// The key, if any, applied when a database is opened.
    fileprivate enum KeyMaterial {
        case passphrase(String)
        case raw(Data)
        case none

        var isEncrypted: Bool {
            if case .none = self { return false }
            return true
        }
    }

    fileprivate static func validateRawKey(_ rawKey: Data) throws {
        guard rawKey.count == rawKeyLength else {
            throw SqlCipherError.invalidKey(
                reason: "a raw key must be \(rawKeyLength) bytes, got \(rawKey.count)")
        }
    }

    /// Calls `body` with SQLCipher's blob-literal form of `rawKey`,
    /// `x'<64 hex digits>'`, then overwrites the temporary buffer.
    fileprivate static func withRawKeyLiteral<R>(
        _ rawKey: Data,
        _ body: (UnsafeRawPointer, Int32) -> R
    ) -> R {
        let hexDigits = Array("0123456789abcdef".utf8)
        var literal = [UInt8]()
        literal.reserveCapacity(rawKey.count * 2 + 3)
        literal.append(UInt8(ascii: "x"))
        literal.append(UInt8(ascii: "'"))
        for byte in rawKey {
            literal.append(hexDigits[Int(byte >> 4)])
            literal.append(hexDigits[Int(byte & 0x0F)])
        }
        literal.append(UInt8(ascii: "'"))
        defer {
            literal.withUnsafeMutableBytes { buffer in
                _ = memset(buffer.baseAddress!, 0, buffer.count)
            }
        }
        return literal.withUnsafeBytes { buffer in
            body(buffer.baseAddress!, Int32(buffer.count))
        }
    }

    fileprivate static func applyKey(_ key: KeyMaterial, to db: OpaquePointer) throws {
        let rc: Int32
        switch key {
        case .none:
            return
        case .passphrase(let passphrase):
            rc = sqlite3_key(db, passphrase, Int32(passphrase.utf8.count))
        case .raw(let rawKey):
            rc = withRawKeyLiteral(rawKey) { sqlite3_key(db, $0, $1) }
        }
        guard rc == SQLITE_OK else { throw SqlCipherError.keyFailed(code: rc) }
    }

    /// Reads the schema so that a wrong key, or an encrypted file opened as
    /// unencrypted, fails here rather than on the first query.  For a new
    /// (empty) database this succeeds without touching the file.
    fileprivate static func verifyReadable(_ db: OpaquePointer, encrypted: Bool) throws {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master", -1, &stmt, nil)
        if let stmt { sqlite3_finalize(stmt) }
        guard rc == SQLITE_OK else {
            throw encrypted
                ? SqlCipherError.keyFailed(code: rc)
                : SqlCipherError.notPlaintextDatabase(code: rc)
        }
    }

    /// Sets the journal mode of a new database, or reads that of an existing one.
    ///
    /// A database is new when it has no pages yet.  The journal mode of an
    /// existing database is never changed.  In-memory and temporary databases
    /// (path `":memory:"` or `""`) have no file to record a mode in; SQLite
    /// always gives them an in-memory rollback journal, reported as
    /// ``JournalMode/rollback``.
    fileprivate static func resolveJournalMode(
        _ db: OpaquePointer,
        requested: JournalMode
    ) throws -> JournalMode {
        if let filename = sqlite3_db_filename(db, "main"), filename.pointee == 0 {
            return .rollback
        }
        let pageCount = try pragmaText(db, "PRAGMA page_count")
        if pageCount == "0" {
            let actual = try pragmaText(db, "PRAGMA journal_mode = \(requested.pragmaValue)")
            guard actual?.lowercased() == requested.sqliteName else {
                throw SqlCipherError.journalModeFailed(requested: requested, actual: actual ?? "")
            }
            return requested
        }
        let current = try pragmaText(db, "PRAGMA journal_mode") ?? ""
        guard let mode = JournalMode(sqliteName: current) else {
            throw SqlCipherError.unsupportedJournalMode(current)
        }
        return mode
    }

    /// Runs a PRAGMA and returns the first column of its first row as text.
    private static func pragmaText(_ db: OpaquePointer, _ sql: String) throws -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            if let stmt { sqlite3_finalize(stmt) }
            throw SqlCipherError.prepareFailed(
                sql: sql, message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_ROW || rc == SQLITE_DONE else {
            throw SqlCipherError.stepFailed(message: String(cString: sqlite3_errmsg(db)))
        }
        guard rc == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: text)
    }
}
