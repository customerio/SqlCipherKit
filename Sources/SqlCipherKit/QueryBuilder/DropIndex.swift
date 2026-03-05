// MARK: - DropIndex

/// Builds a `DROP INDEX` statement.
///
/// ```swift
/// struct DropEmailIndex: Migration {
///     let id = "007-drop-email-index"
///     func up(_ ctx: MigrationContext) throws {
///         try ctx.execute(DropIndex("idx_users_email"))
///     }
///     func down(_ ctx: MigrationContext) throws {
///         try ctx.execute(
///             CreateIndex("idx_users_email", on: TableName("users"))
///                 .column("email")
///         )
///     }
/// }
/// ```
///
/// `ifExists` defaults to `true`, producing `DROP INDEX IF EXISTS`.
public struct DropIndex: Sendable {

    private let indexName: String
    private let ifExists: Bool

    public init(_ name: String, ifExists: Bool = true) {
        self.indexName = name
        self.ifExists = ifExists
    }

    // MARK: - Build

    /// Renders the statement to a ``BuiltQuery`` (no bindings — DDL is inline).
    public func build() -> BuiltQuery {
        let guard_ = ifExists ? "IF EXISTS " : ""
        return BuiltQuery(sql: "DROP INDEX \(guard_)\(indexName)", bindings: [:])
    }
}
