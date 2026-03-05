import CSqlCipher
import Foundation

// MARK: - Internal statement helpers

/// Prepares an SQL statement and binds parameters, returning a finalise-on-deinit handle.
final class PreparedStatement {
    let handle: OpaquePointer

    init(db: OpaquePointer, sql: String) throws {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let s = stmt else {
            throw SqlCipherError.prepareFailed(
                sql: sql,
                message: String(cString: sqlite3_errmsg(db))
            )
        }
        self.handle = s
    }

    deinit {
        sqlite3_finalize(handle)
    }
}

// MARK: - Connection

/// A synchronous, non-copyable view of an open database.
///
/// `Connection` is always obtained through ``Database/withConnection(_:)`` and
/// is confined to the closure's scope by two complementary compiler guarantees:
///
/// - `~Copyable` — the value cannot be copied into another variable.
/// - `borrowing` parameter in `withConnection` — the closure receives the
///   connection as a *borrow*, which the compiler prohibits from being consumed
///   (moved out). Together these make it impossible to store the `Connection`
///   beyond the enclosing `withConnection` call.
///
/// All methods execute synchronously; the surrounding `Database` actor
/// guarantees serialised, thread-safe access.
public struct Connection: ~Copyable {

    // MARK: - Storage

    /// The raw `sqlite3 *` handle, owned by the surrounding `Database` actor.
    let db: OpaquePointer

    // MARK: - Init (internal only)

    init(db: OpaquePointer) {
        self.db = db
    }

    // MARK: - Execute (write / DDL)

    /// Executes an SQL statement that produces no result rows (INSERT, UPDATE,
    /// DELETE, CREATE, …).
    ///
    /// - Parameters:
    ///   - sql:      The SQL text, optionally containing `?` placeholders.
    ///   - bindings: Values to bind to each `?` in order.
    public func execute(_ sql: String, _ bindings: any SQLConvertible...) throws {
        try _execute(sql, bindings: bindings)
    }

    // MARK: - Query (read)

    /// Executes a SELECT and returns all matching rows.
    ///
    /// - Parameters:
    ///   - sql:      The SQL text, optionally containing `?` placeholders.
    ///   - bindings: Values to bind to each `?` in order.
    /// - Returns: An array containing one ``Row`` per result row (empty if no
    ///            rows matched).
    public func query(_ sql: String, _ bindings: any SQLConvertible...) throws -> [Row] {
        try _query(sql, bindings: bindings)
    }

    // MARK: - Scalar query

    /// Executes a SELECT and returns the first column of the first result row
    /// converted to `T`.
    ///
    /// Returns `nil` when the result set is empty or the column holds `NULL`.
    ///
    /// ```swift
    /// let count = try conn.scalarQuery("SELECT COUNT(*) FROM users", as: Int.self)
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
        try _scalarQuery(sql, bindings: bindings, as: T.self)
    }

    // MARK: - Internal array-based entries (used by Database for forwarding)

    func _execute(_ sql: String, bindings: [any SQLConvertible]) throws {
        let stmt = try PreparedStatement(db: db, sql: sql)
        try bind(stmt.handle, bindings)
        let rc = sqlite3_step(stmt.handle)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw SqlCipherError.stepFailed(
                message: String(cString: sqlite3_errmsg(db))
            )
        }
    }

    func _query(_ sql: String, bindings: [any SQLConvertible]) throws -> [Row] {
        let stmt = try PreparedStatement(db: db, sql: sql)
        try bind(stmt.handle, bindings)
        return try collectRows(stmt.handle)
    }

    func _scalarQuery<T: SQLConvertible>(
        _ sql: String,
        bindings: [any SQLConvertible],
        as type: T.Type = T.self
    ) throws -> T? {
        let stmt = try PreparedStatement(db: db, sql: sql)
        try bind(stmt.handle, bindings)
        guard sqlite3_step(stmt.handle) == SQLITE_ROW else { return nil }
        return T.from(sqlValue: readValue(stmt.handle, column: 0))
    }
}

// MARK: - Private helpers

extension Connection {
    private func bind(_ stmt: OpaquePointer, _ values: [any SQLConvertible]) throws {
        for (i, val) in values.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch val.sqlValue {
            case .null:
                rc = sqlite3_bind_null(stmt, idx)
            case .integer(let n):
                rc = sqlite3_bind_int64(stmt, idx, n)
            case .real(let d):
                rc = sqlite3_bind_double(stmt, idx, d)
            case .text(let s):
                rc = sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT_SHIM)
            case .blob(let d):
                rc = d.withUnsafeBytes { ptr in
                    sqlite3_bind_blob(stmt, idx, ptr.baseAddress, Int32(ptr.count), SQLITE_TRANSIENT_SHIM)
                }
            }
            guard rc == SQLITE_OK else {
                throw SqlCipherError.bindFailed(index: idx, code: rc)
            }
        }
    }

    private func collectRows(_ stmt: OpaquePointer) throws -> [Row] {
        let colCount = Int(sqlite3_column_count(stmt))
        var columnIndex: [String: Int] = [:]
        for i in 0..<colCount {
            if let name = sqlite3_column_name(stmt, Int32(i)) {
                columnIndex[String(cString: name)] = i
            }
        }

        var rows: [Row] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                let values = (0..<colCount).map { readValue(stmt, column: Int32($0)) }
                rows.append(Row(columnIndex: columnIndex, values: values))
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw SqlCipherError.stepFailed(
                    message: String(cString: sqlite3_errmsg(db))
                )
            }
        }
        return rows
    }

    private func readValue(_ stmt: OpaquePointer, column: Int32) -> Value {
        switch sqlite3_column_type(stmt, column) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(stmt, column))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(stmt, column))
        case SQLITE_TEXT:
            let ptr = sqlite3_column_text(stmt, column)!
            return .text(String(cString: ptr))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(stmt, column))
            if count == 0 { return .blob(Data()) }
            let ptr = sqlite3_column_blob(stmt, column)!
            return .blob(Data(bytes: ptr, count: count))
        default: // SQLITE_NULL
            return .null
        }
    }
}

// MARK: - SQLITE_TRANSIENT shim
//
// sqlite3_bind_* expects a destructor function pointer; SQLITE_TRANSIENT (−1)
// tells SQLite to copy the data before bind returns.  We expose it as a typed
// Swift constant via the C shim header.

private let SQLITE_TRANSIENT_SHIM = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
