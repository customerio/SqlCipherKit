// MARK: - ColumnType

/// The storage class / type affinity of a SQLite column.
public enum ColumnType: String, Sendable {
    case integer = "INTEGER"
    case text    = "TEXT"
    case real    = "REAL"
    case blob    = "BLOB"
    case numeric = "NUMERIC"
}

// MARK: - ColumnConstraint

/// A constraint applied to a column in a `CREATE TABLE` or `ADD COLUMN` statement.
public enum ColumnConstraint: Sendable {
    /// `PRIMARY KEY`
    case primaryKey
    /// `PRIMARY KEY AUTOINCREMENT` (INTEGER columns only; implies `NOT NULL`).
    case autoIncrement
    /// `NOT NULL`
    case notNull
    /// `UNIQUE`
    case unique
    /// `DEFAULT <value>` — rendered as an inline SQL literal (not a binding).
    case `default`(any SQLConvertible)
    /// `CHECK (<expr>)` — supply the expression as a raw SQL string.
    ///
    /// ```swift
    /// .check("score >= 0 AND score <= 100")
    /// ```
    case check(String)
    /// `REFERENCES table(column)` — a simple foreign-key constraint.
    case references(TableName, column: String)

    func render() -> String {
        switch self {
        case .primaryKey:
            return "PRIMARY KEY"
        case .autoIncrement:
            return "PRIMARY KEY AUTOINCREMENT"
        case .notNull:
            return "NOT NULL"
        case .unique:
            return "UNIQUE"
        case .default(let v):
            return "DEFAULT \(v.sqlValue.sqlLiteral)"
        case .check(let expr):
            return "CHECK (\(expr))"
        case .references(let table, let column):
            return "REFERENCES \(table.name)(\(column))"
        }
    }
}

// MARK: - ColumnDefinition

/// A fully described column suitable for use in `CREATE TABLE` or `ADD COLUMN`.
///
/// ```swift
/// ColumnDefinition("id",    .integer, .autoIncrement)
/// ColumnDefinition("name",  .text,    .notNull)
/// ColumnDefinition("score", .real,    .default(0.0), .check("score >= 0"))
/// ```
public struct ColumnDefinition: Sendable {
    public let name: String
    public let type: ColumnType
    public let constraints: [ColumnConstraint]

    public init(_ name: String, _ type: ColumnType, _ constraints: ColumnConstraint...) {
        self.name = name
        self.type = type
        self.constraints = constraints
    }

    init(_ name: String, _ type: ColumnType, constraints: [ColumnConstraint]) {
        self.name = name
        self.type = type
        self.constraints = constraints
    }

    func render() -> String {
        var parts = [name, type.rawValue]
        parts += constraints.map { $0.render() }
        return parts.joined(separator: " ")
    }
}

// MARK: - Value inline-literal rendering (DDL only)
//
// Used by ColumnConstraint.default to embed literal values directly in the
// SQL string rather than via a bound parameter (which SQLite does not support
// in DDL).

extension Value {
    var sqlLiteral: String {
        switch self {
        case .null:           return "NULL"
        case .integer(let n): return "\(n)"
        case .real(let d):    return "\(d)"
        case .text(let s):    return "'\(s.replacingOccurrences(of: "'", with: "''"))'"
        case .blob:           return "NULL"
        }
    }
}
