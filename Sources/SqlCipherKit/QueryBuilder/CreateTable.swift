// MARK: - CreateTable

/// Builds a `CREATE TABLE` statement using a fluent column-definition API.
///
/// ```swift
/// let users = TableName("users")
///
/// let create = CreateTable(users)
///     .column("id",    .integer, .autoIncrement)
///     .column("name",  .text,    .notNull)
///     .column("email", .text,    .notNull, .unique)
///     .column("score", .real,    .default(0.0))
///
/// try await db.execute(create)
/// ```
///
/// `ifNotExists` defaults to `true`, producing `CREATE TABLE IF NOT EXISTS`.
public struct CreateTable: Sendable {

    private let table: TableName
    private var columns: [ColumnDefinition]
    private let ifNotExists: Bool

    public init(_ table: TableName, ifNotExists: Bool = true) {
        self.table = table
        self.columns = []
        self.ifNotExists = ifNotExists
    }

    // MARK: - Fluent column builders

    /// Adds a column using individual constraint values.
    public func column(_ name: String, _ type: ColumnType, _ constraints: ColumnConstraint...)
        -> CreateTable {
        var next = self
        next.columns.append(ColumnDefinition(name, type, constraints: constraints))
        return next
    }

    /// Adds a pre-built ``ColumnDefinition``.
    public func column(_ def: ColumnDefinition) -> CreateTable {
        var next = self
        next.columns.append(def)
        return next
    }

    // MARK: - Build

    /// Renders the statement to a ``BuiltQuery`` (no bindings — DDL is inline).
    public func build() -> BuiltQuery {
        let guard_ = ifNotExists ? "IF NOT EXISTS " : ""
        let colSQL = columns.map { "    \($0.render())" }.joined(separator: ",\n")
        let sql = "CREATE TABLE \(guard_)\(table.name) (\n\(colSQL)\n)"
        return BuiltQuery(sql: sql, bindings: [:])
    }
}
