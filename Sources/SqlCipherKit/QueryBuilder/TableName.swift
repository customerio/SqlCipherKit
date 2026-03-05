// MARK: - TableName

/// A reference to a database table.
///
/// Define tables as constants once and attach an alias at the use-site with
/// ``alias(_:)``:
///
/// ```swift
/// let users  = TableName("users")
/// let orders = TableName("orders")
///
/// // At the use-site:
/// Select(.all)
///     .from(users.alias("u"))
///     .join(orders.alias("o"), on: col(users.alias("u"), "id") == col(orders.alias("o"), "user_id"))
/// ```
public struct TableName: Sendable, Hashable {

    /// The physical table name as it appears in the schema.
    public let name: String

    /// An optional SQL alias (`AS <alias>`) applied at the use-site via ``alias(_:)``.
    public let alias: String?

    public init(_ name: String) {
        self.name = name
        self.alias = nil
    }

    /// Returns a copy of this `TableName` with the given alias applied.
    ///
    /// ```swift
    /// let u = users.alias("u")   // rendered as `users AS u` in FROM/JOIN
    /// ```
    public func alias(_ a: String) -> TableName {
        TableName(name: name, alias: a)
    }

    /// Memberwise init used by ``alias(_:)`` and the CTE rendering path.
    init(name: String, alias: String?) {
        self.name = name
        self.alias = alias
    }

    // MARK: - Internal

    /// The token used to qualify column references: the alias if present,
    /// otherwise the bare table name.
    public var qualifier: String { alias ?? name }

    /// The SQL fragment for the FROM / JOIN clause, e.g. `users AS u`.
    public var fromSQL: String {
        if let alias { return "\(name) AS \(alias)" }
        return name
    }
}
