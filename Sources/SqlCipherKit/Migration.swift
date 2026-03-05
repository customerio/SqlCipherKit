import Foundation

// MARK: - MigrationContext

/// A scoped DDL/DML handle passed to each ``Migration`` body.
///
/// `MigrationContext` exposes the same write-oriented API as ``Connection``
/// but is a regular class (reference type), so it can be captured by the
/// stored migration closure without running into `~Copyable` restrictions.
///
/// The context is valid only for the duration of the migration body call;
/// do not store it beyond that closure.
public final class MigrationContext: Sendable {

    // MARK: - Storage

    /// The raw `sqlite3 *` handle, owned by the surrounding `Database`.
    nonisolated(unsafe) private let _db: OpaquePointer
    /// Shared statement cache, owned by the surrounding `Database`.
    nonisolated(unsafe) private let _cache: StatementCache

    // MARK: - Init (internal)

    init(db: OpaquePointer, cache: StatementCache) {
        _db = db
        _cache = cache
    }

    // MARK: - Private helper

    /// Borrows a short-lived `Connection` backed by the same handle and cache.
    private func withConn<R>(_ body: (borrowing Connection) throws -> R) rethrows -> R {
        try body(Connection(db: _db, cache: _cache))
    }

    // MARK: - Execute: raw SQL

    /// Executes a raw SQL statement (no result rows expected).
    public func execute(_ sql: String, _ bindings: any SQLConvertible...) throws {
        try withConn { try $0._execute(sql, bindings: bindings) }
    }

    // MARK: - Execute: DDL builders

    /// Creates a table using a ``CreateTable`` builder.
    public func execute(_ create: CreateTable) throws {
        try withConn { try $0._execute(create.build()) }
    }

    /// Alters a table using an ``AlterTable`` builder.
    public func execute(_ alter: AlterTable) throws {
        try withConn { try $0._execute(alter.build()) }
    }

    /// Drops a table using a ``DropTable`` builder.
    public func execute(_ drop: DropTable) throws {
        try withConn { try $0._execute(drop.build()) }
    }

    /// Creates an index using a ``CreateIndex`` builder.
    public func execute(_ create: CreateIndex) throws {
        try withConn { try $0._execute(create.build()) }
    }

    /// Drops an index using a ``DropIndex`` builder.
    public func execute(_ drop: DropIndex) throws {
        try withConn { try $0._execute(drop.build()) }
    }

    // MARK: - Execute: DML builders

    /// Inserts a row using an ``Insert`` builder.
    public func execute(_ insert: Insert, _ params: ParamBinding...) throws {
        try withConn { try $0._execute(insert.build(params: params)) }
    }

    /// Updates rows using an ``Update`` builder.
    public func execute(_ update: Update, _ params: ParamBinding...) throws {
        try withConn { try $0._execute(update.build(params: params)) }
    }

    // MARK: - Query helpers (useful for data migrations)

    /// Executes a raw SQL SELECT and returns all matching rows.
    public func query(_ sql: String, _ bindings: any SQLConvertible...) throws -> [Row] {
        try withConn { try $0._query(sql, bindings: bindings) }
    }
}

// MARK: - Migration

/// A named, reversible database schema change.
///
/// Conform your own type to `Migration` — typically a dedicated file per
/// migration — to describe a schema or data change that the database can
/// both apply and undo:
///
/// ```swift
/// // Migrations/001_CreateUsers.swift
/// struct CreateUsers: Migration {
///     let id = "001-create-users"
///
///     func up(_ ctx: MigrationContext) throws {
///         try ctx.execute(
///             CreateTable(TableName("users"))
///                 .column("id",    .integer, .autoIncrement)
///                 .column("name",  .text,    .notNull)
///                 .column("email", .text,    .notNull, .unique)
///         )
///     }
///
///     func down(_ ctx: MigrationContext) throws {
///         try ctx.execute("DROP TABLE users")
///     }
/// }
/// ```
///
/// Pass an ordered array of migration instances to ``Database/migrate(_:)``.
/// Dependent migrations must appear after their prerequisites in the array.
/// Use ``Database/rollback(to:using:)`` to reverse applied migrations in
/// reverse order down to (and including) the target migration.
public protocol Migration: Sendable {

    /// A stable, unique identifier used to track whether this migration has
    /// already been applied.  Conventional formats include `"001-create-users"`
    /// or `"2024-01-15-add-score-column"`.
    var id: String { get }

    /// Applies the migration (schema / data changes).
    ///
    /// Called inside a transaction.  Throwing rolls back all changes made
    /// during this migration and halts further migrations.
    func up(_ ctx: MigrationContext) throws

    /// Reverses the migration, restoring the database to its previous state.
    ///
    /// Called inside a transaction by ``Database/rollback(to:using:)``.
    /// Throwing rolls back all changes made during this reversal.
    ///
    /// If the migration cannot be reversed (e.g. destructive data changes),
    /// implement this method as a no-op or throw a descriptive error.
    func down(_ ctx: MigrationContext) throws
}
