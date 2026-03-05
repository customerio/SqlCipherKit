// MARK: - DropTable

/// Builds a `DROP TABLE` statement.
///
/// ```swift
/// struct DropLegacy: Migration {
///     let id = "005-drop-legacy"
///     func up(_ ctx: MigrationContext) throws {
///         try ctx.execute(DropTable(TableName("legacy")))
///     }
///     func down(_ ctx: MigrationContext) throws {
///         try ctx.execute("CREATE TABLE legacy (id INTEGER PRIMARY KEY)")
///     }
/// }
/// ```
///
/// `ifExists` defaults to `true`, producing `DROP TABLE IF EXISTS`.
public struct DropTable: Sendable {

    private let table: TableName
    private let ifExists: Bool

    public init(_ table: TableName, ifExists: Bool = true) {
        self.table = table
        self.ifExists = ifExists
    }

    // MARK: - Build

    /// Renders the statement to a ``BuiltQuery`` (no bindings — DDL is inline).
    public func build() -> BuiltQuery {
        let guard_ = ifExists ? "IF EXISTS " : ""
        return BuiltQuery(sql: "DROP TABLE \(guard_)\(table.name)", bindings: [:])
    }
}
