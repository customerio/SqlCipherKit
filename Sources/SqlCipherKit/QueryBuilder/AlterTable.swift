// MARK: - AlterTable

/// Builds an `ALTER TABLE` statement.
///
/// SQLite supports four forms of `ALTER TABLE`, each represented by a
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
///
/// // Drop a column (SQLite 3.35+)
/// AlterTable(users, dropColumn: "legacy_field")
/// ```
///
/// Each `AlterTable` represents exactly one DDL operation, matching SQLite's
/// own restriction.
public struct AlterTable: Sendable {

    private enum Operation: Sendable {
        case renameTo(String)
        case renameColumn(String, to: String)
        case addColumn(ColumnDefinition)
        case dropColumn(String)
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
    public init(
        _ table: TableName, addColumn name: String, _ type: ColumnType,
        _ constraints: ColumnConstraint...
    ) {
        self.table = table
        self.operation = .addColumn(ColumnDefinition(name, type, constraints: constraints))
    }

    /// `ALTER TABLE <table> ADD COLUMN <def>` — accepts a pre-built definition.
    public init(_ table: TableName, addColumn def: ColumnDefinition) {
        self.table = table
        self.operation = .addColumn(def)
    }

    /// `ALTER TABLE <table> DROP COLUMN <name>`
    ///
    /// Requires SQLite 3.35.0 or later (bundled SqlCipher 4.x satisfies this).
    /// The column must not be referenced by an index, primary key, unique
    /// constraint, or CHECK constraint — SQLite will return an error if it is.
    public init(_ table: TableName, dropColumn name: String) {
        self.table = table
        self.operation = .dropColumn(name)
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
        case .dropColumn(let name):
            sql = "ALTER TABLE \(table.name) DROP COLUMN \(name)"
        }
        return BuiltQuery(sql: sql, bindings: [:])
    }
}
