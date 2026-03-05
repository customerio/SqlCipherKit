// MARK: - AlterTable

/// Builds an `ALTER TABLE` statement.
///
/// SQLite supports three forms of `ALTER TABLE`, each represented by a
/// separate initialiser:
///
/// ```swift
/// let users = TableName("users")
///
/// // Rename the table
/// AlterTable(users, renameTo: "people")
///
/// // Rename a column (SQLite 3.25+)
/// AlterTable(users, renameColumn: "email", to: "email_address")
///
/// // Add a column
/// AlterTable(users, addColumn: "bio", .text)
/// AlterTable(users, addColumn: "score", .real, .notNull, .default(0.0))
/// ```
///
/// Each `AlterTable` represents exactly one DDL operation, matching SQLite's
/// own restriction.
public struct AlterTable: Sendable {

    private enum Operation: Sendable {
        case renameTo(String)
        case renameColumn(String, to: String)
        case addColumn(ColumnDefinition)
    }

    private let table: TableName
    private let operation: Operation

    // MARK: - Initialisers

    /// `ALTER TABLE <table> RENAME TO <newName>`
    public init(_ table: TableName, renameTo newName: String) {
        self.table = table
        self.operation = .renameTo(newName)
    }

    /// `ALTER TABLE <table> RENAME COLUMN <old> TO <new>`
    ///
    /// Requires SQLite 3.25.0 or later (bundled SqlCipher 4.x satisfies this).
    public init(_ table: TableName, renameColumn old: String, to new: String) {
        self.table = table
        self.operation = .renameColumn(old, to: new)
    }

    /// `ALTER TABLE <table> ADD COLUMN <name> <type> [constraints…]`
    public init(_ table: TableName, addColumn name: String, _ type: ColumnType,
                _ constraints: ColumnConstraint...)
    {
        self.table = table
        self.operation = .addColumn(ColumnDefinition(name, type, constraints: constraints))
    }

    /// `ALTER TABLE <table> ADD COLUMN <def>` — accepts a pre-built definition.
    public init(_ table: TableName, addColumn def: ColumnDefinition) {
        self.table = table
        self.operation = .addColumn(def)
    }

    // MARK: - Build

    /// Renders the statement to a ``BuiltQuery`` (no bindings — DDL is inline).
    public func build() -> BuiltQuery {
        let sql: String
        switch operation {
        case .renameTo(let newName):
            sql = "ALTER TABLE \(table.name) RENAME TO \(newName)"
        case .renameColumn(let old, let new):
            sql = "ALTER TABLE \(table.name) RENAME COLUMN \(old) TO \(new)"
        case .addColumn(let def):
            sql = "ALTER TABLE \(table.name) ADD COLUMN \(def.render())"
        }
        return BuiltQuery(sql: sql, bindings: [:])
    }
}
