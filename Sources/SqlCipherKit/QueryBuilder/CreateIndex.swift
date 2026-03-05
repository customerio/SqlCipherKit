// MARK: - SortDirection (index)

/// Sort direction for a column within a ``CreateIndex`` definition.
public enum IndexSortDirection: String, Sendable {
    case ascending  = "ASC"
    case descending = "DESC"
}

// MARK: - CreateIndex

/// Builds a `CREATE INDEX` statement using a fluent column API.
///
/// ```swift
/// let users = TableName("users")
///
/// // Simple index
/// let idx = CreateIndex("idx_users_email", on: users)
///     .column("email")
///
/// // Composite unique index with explicit sort directions
/// let uq = CreateIndex("idx_users_name_email", on: users, unique: true)
///     .column("name",  .ascending)
///     .column("email", .descending)
/// ```
///
/// `ifNotExists` defaults to `true`, producing `CREATE INDEX IF NOT EXISTS`.
public struct CreateIndex: Sendable {

    private let indexName: String
    private let table: TableName
    private var columns: [(name: String, direction: IndexSortDirection?)]
    private let isUnique: Bool
    private let ifNotExists: Bool

    public init(
        _ name: String,
        on table: TableName,
        unique: Bool = false,
        ifNotExists: Bool = true
    ) {
        self.indexName = name
        self.table = table
        self.columns = []
        self.isUnique = unique
        self.ifNotExists = ifNotExists
    }

    // MARK: - Fluent column builders

    /// Appends a column, with an optional explicit sort direction.
    ///
    /// When `direction` is `nil` SQLite uses its default (ascending).
    public func column(_ name: String, _ direction: IndexSortDirection? = nil) -> CreateIndex {
        var next = self
        next.columns.append((name, direction))
        return next
    }

    // MARK: - Build

    /// Renders the statement to a ``BuiltQuery`` (no bindings — DDL is inline).
    public func build() -> BuiltQuery {
        let unique_     = isUnique    ? "UNIQUE "      : ""
        let guard_      = ifNotExists ? "IF NOT EXISTS " : ""
        let colSQL = columns.map { col in
            col.direction.map { "\(col.name) \($0.rawValue)" } ?? col.name
        }.joined(separator: ", ")
        let sql = "CREATE \(unique_)INDEX \(guard_)\(indexName) ON \(table.name) (\(colSQL))"
        return BuiltQuery(sql: sql, bindings: [:])
    }
}
