// MARK: - Database: raw-SQL convenience overloads
//
// Simple, one-shot wrappers around ``Connection``'s internal methods.
// Each call opens a connection, runs the statement, and returns — no
// transaction management or builder types involved.

extension Database {

    // MARK: execute

    /// Executes an SQL statement that produces no result rows (INSERT, UPDATE,
    /// DELETE, CREATE, …).
    ///
    /// - Parameters:
    ///   - sql:      The SQL text, optionally containing `?` placeholders.
    ///   - bindings: Values to bind to each `?` in order.
    public func execute(_ sql: String, _ bindings: any SQLConvertible...) throws {
        try withConnection { try $0._execute(sql, bindings: bindings) }
    }

    // MARK: query

    /// Executes a SELECT and returns all matching rows.
    ///
    /// - Parameters:
    ///   - sql:      The SQL text, optionally containing `?` placeholders.
    ///   - bindings: Values to bind to each `?` in order.
    /// - Returns: An array containing one ``Row`` per result row.
    public func query(_ sql: String, _ bindings: any SQLConvertible...) throws -> [Row] {
        try withConnection { try $0._query(sql, bindings: bindings) }
    }

    // MARK: scalarQuery

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
}
