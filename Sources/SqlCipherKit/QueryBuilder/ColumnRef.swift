// MARK: - ColumnRef

/// A reference to a database column, optionally qualified by a table and/or
/// given a result-set alias.
///
/// Define columns as constants and attach a table qualifier or result-set alias
/// at the use-site with ``of(_:)`` and ``alias(_:)``:
///
/// ```swift
/// let users = TableName("users")
/// let u     = users.alias("u")
///
/// let id    = col("id")
/// let name  = col("name")
///
/// // At the use-site:
/// id.of(u)                    // u.id
/// name.of(u).alias("n")       // u.name AS n
/// col("*")                    // *
/// ColumnRef.all               // *
/// ```
public struct ColumnRef: Sendable, Hashable {

    // MARK: - Properties

    /// Optional table qualifier (the alias if the table has one, else the name).
    public let tableQualifier: String?

    /// The physical column name, or `*` for a wildcard select.
    public let name: String

    /// Optional result-set alias (`AS <alias>`).
    public let alias: String?

    // MARK: - Initialisers

    /// Creates an unqualified column reference.
    public init(_ name: String) {
        self.tableQualifier = nil
        self.name = name
        self.alias = nil
    }

    /// A column reference qualified by the given table (or aliased table).
    /// Prefer using ``of(_:)`` on an existing ``ColumnRef`` constant instead.
    public init(_ table: TableName, _ name: String) {
        self.tableQualifier = table.qualifier
        self.name = name
        self.alias = nil
    }

    /// Direct memberwise initialiser (internal — backs ``of(_:)`` and ``alias(_:)``).
    init(tableQualifier: String?, name: String, alias: String?) {
        self.tableQualifier = tableQualifier
        self.name = name
        self.alias = alias
    }

    // MARK: - Use-site modifiers

    /// Returns a copy of this `ColumnRef` qualified by `table`.
    ///
    /// ```swift
    /// let id   = col("id")
    /// let name = col("name")
    ///
    /// let u = users.alias("u")
    /// id.of(u)               // renders as u.id
    /// name.of(u).alias("n")  // renders as u.name AS n
    /// ```
    public func of(_ table: TableName) -> ColumnRef {
        ColumnRef(tableQualifier: table.qualifier, name: name, alias: alias)
    }

    /// Returns a copy of this `ColumnRef` with the given result-set alias applied.
    ///
    /// ```swift
    /// col("score").alias("s")          // renders as `score AS s` in SELECT
    /// col("score").of(u).alias("s")    // renders as `u.score AS s`
    /// ```
    public func alias(_ a: String) -> ColumnRef {
        ColumnRef(tableQualifier: tableQualifier, name: name, alias: a)
    }

    // MARK: - Special values

    /// Wildcard — renders as `*`.
    public static let all = ColumnRef("*")

    // MARK: - Internal rendering helpers

    /// The qualified column name used in WHERE / ON / ORDER BY clauses.
    ///
    /// - `u.name` when a table qualifier is present.
    /// - `name`   otherwise.
    public var sqlName: String {
        if let tq = tableQualifier { return "\(tq).\(name)" }
        return name
    }

    /// The full expression used in the SELECT list.
    ///
    /// - `*`          for `.all`
    /// - `name`       for an unaliased, unqualified column
    /// - `u.name`     for a qualified, unaliased column
    /// - `name AS a`  for an aliased column
    /// - `u.name AS a` for a qualified, aliased column
    public var selectSQL: String {
        if name == "*" { return "*" }
        let base = sqlName
        if let alias { return "\(base) AS \(alias)" }
        return base
    }
}

// MARK: - Free helpers

/// Creates an unqualified ``ColumnRef``.
///
/// ```swift
/// let id    = col("id")
/// let score = col("score")
///
/// // At the use-site:
/// id.of(users.alias("u"))            // u.id
/// score.of(t).alias("s")             // t.score AS s
/// ```
public func col(_ name: String) -> ColumnRef {
    ColumnRef(name)
}

/// Creates a ``ColumnRef`` qualified by a `TableName` (or aliased table).
///
/// This is a shorthand for `col(name).of(table)` and is useful when you don't
/// need a reusable constant:
/// ```swift
/// col(users.alias("u"), "name")       // u.name
/// col(u, "name").alias("n")           // u.name AS n
/// ```
public func col(_ table: TableName, _ name: String) -> ColumnRef {
    col(name).of(table)
}

/// Creates a ``ColumnRef`` qualified by a table-name string (alias or bare name).
///
/// Useful in JOIN ON expressions where you're referring to an alias directly:
/// ```swift
/// col("u", "id") == col("o", "user_id")
/// ```
public func col(_ tableQualifier: String, _ name: String) -> ColumnRef {
    ColumnRef(tableQualifier: tableQualifier, name: name, alias: nil)
}
