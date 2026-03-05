// MARK: - RenderContext

/// Accumulates parameter bindings as a `Select` expression tree is rendered to
/// SQL.  Literal values are auto-named `_0`, `_1`, … so that two queries with
/// different literal values still produce the **same SQL string** and can share
/// a statement-cache entry.
public struct RenderContext {
    public var bindings: [String: any SQLConvertible] = [:]
    private var counter = 0

    public init() {}

    /// Renders an ``SQLValue`` to a placeholder string (e.g. `:_0` or `:name`)
    /// and records any associated literal in `bindings`.
    public mutating func render(_ value: SQLValue) -> String {
        switch value {
        case .literal(let v):
            let key = "_\(counter)"
            counter += 1
            bindings[key] = v
            return ":\(key)"
        case .param(let name):
            return ":\(name)"
        }
    }
}

// MARK: - BuiltQuery

/// The concrete SQL string and its named bindings, ready to pass to SQLite.
///
/// Produce a `BuiltQuery` by calling ``Select/build(params:)``.
public struct BuiltQuery: Sendable {
    /// The SQL string with all values replaced by `:name` placeholders.
    public let sql: String
    /// All named bindings — both literals (`_0`, `_1`, …) and any caller-
    /// supplied ``Param`` values.
    public let bindings: [String: any SQLConvertible]
}

// MARK: - JoinType

/// The SQL join flavour used in a ``Select/join(_:type:on:)`` clause.
public enum JoinType: Sendable {
    case inner
    case left
    case right
    case cross

    var sql: String {
        switch self {
        case .inner: return "INNER JOIN"
        case .left: return "LEFT JOIN"
        case .right: return "RIGHT JOIN"
        case .cross: return "CROSS JOIN"
        }
    }
}

// MARK: - SortDirection

/// Ascending or descending sort order.
public enum SortDirection: Sendable {
    case ascending
    case descending

    var sql: String { self == .ascending ? "ASC" : "DESC" }
}

// MARK: - Internal clause types

struct JoinClause: Sendable {
    let table: TableName
    let type: JoinType
    let on: Expression
}

struct OrderByClause: Sendable {
    let column: ColumnRef
    let direction: SortDirection
}

// MARK: - Select

/// A composable, immutable SELECT-statement builder.
///
/// `Select` uses a fluent, value-type API — every method returns a new `Select`
/// — and separates the query *template* from the *values* bound at execution
/// time.  This means the rendered SQL stays constant across calls with
/// different parameter values, maximising reuse of the statement cache.
///
/// ## Basic usage
/// ```swift
/// let q = Select(.all)
///     .from(TableName("users"))
///     .where(col("active") == true)
///     .orderBy(col("name"))
///     .limit(20)
///
/// let rows = try await db.query(q)
/// ```
///
/// ## Named parameters
/// ```swift
/// let minAge  = Param<Int>("minAge")
/// let maxAge  = Param<Int>("maxAge")
///
/// let template = Select(.all)
///     .from(TableName("users"))
///     .where(col("age") >= minAge && col("age") <= maxAge)
///
/// // Same SQL string every time — cache hit guaranteed.
/// let adults = try await db.query(template, minAge.set(18), maxAge.set(65))
/// let seniors = try await db.query(template, minAge.set(65), maxAge.set(120))
/// ```
///
/// ## Recursive CTEs
/// ```swift
/// let cte = CTE(
///     name: "ancestors",
///     columns: ["id", "parent_id", "name"],
///     base: Select(col("id"), col("parent_id"), col("name"))
///         .from(TableName("categories"))
///         .where(col("id") == Param<Int>("rootId")),
///     recursive: Select(col("id").of(categories.alias("c")), col("parent_id").of(categories.alias("c")), col("name").of(categories.alias("c")))
///         .from(categories.alias("c"))
///         .join(ancestors.alias("a"), on: col("parent_id").of(categories.alias("c")) == col("id").of(ancestors.alias("a")))
/// )
///
/// let result = Select(.all)
///     .from(TableName("ancestors"))
///     .with(cte)
///     .build(params: ["rootId": 5])
/// ```
public struct Select: Sendable {

    // Stored as arrays to preserve insertion order.
    private let fields: [ColumnRef]
    private var isDistinct: Bool
    private var ctes: [CTE]
    private var fromTable: TableName?
    private var joins: [JoinClause]
    private var whereExpr: Expression?
    private var orderClauses: [OrderByClause]
    private var limitValue: Int?
    private var offsetValue: Int?

    // MARK: Initialisation

    /// Start a SELECT with an explicit list of columns.
    public init(_ fields: ColumnRef...) {
        self.fields = fields
        self.isDistinct = false
        self.ctes = []
        self.fromTable = nil
        self.joins = []
        self.whereExpr = nil
        self.orderClauses = []
        self.limitValue = nil
        self.offsetValue = nil
    }

    private init(
        fields: [ColumnRef],
        isDistinct: Bool,
        ctes: [CTE],
        fromTable: TableName?,
        joins: [JoinClause],
        whereExpr: Expression?,
        orderClauses: [OrderByClause],
        limitValue: Int?,
        offsetValue: Int?
    ) {
        self.fields = fields
        self.isDistinct = isDistinct
        self.ctes = ctes
        self.fromTable = fromTable
        self.joins = joins
        self.whereExpr = whereExpr
        self.orderClauses = orderClauses
        self.limitValue = limitValue
        self.offsetValue = offsetValue
    }

    // MARK: Fluent modifiers

    /// Add a `WITH` / `WITH RECURSIVE` CTE.  Multiple CTEs are rendered in the
    /// order they are added.
    public func with(_ cte: CTE) -> Select {
        var next = self
        next.ctes.append(cte)
        return next
    }

    /// Specify the primary table in the `FROM` clause.
    public func from(_ table: TableName) -> Select {
        var next = self
        next.fromTable = table
        return next
    }

    /// Convenience overload — creates a plain `TableName` for you.
    public func from(_ name: String) -> Select {
        from(TableName(name))
    }

    /// Add a JOIN clause.
    public func join(_ table: TableName, type: JoinType = .inner, on: Expression) -> Select {
        var next = self
        next.joins.append(JoinClause(table: table, type: type, on: on))
        return next
    }

    /// Set (or replace) the WHERE filter.
    public func `where`(_ expr: Expression) -> Select {
        var next = self
        next.whereExpr = expr
        return next
    }

    /// Append an ORDER BY term.
    public func orderBy(_ column: ColumnRef, _ direction: SortDirection = .ascending) -> Select {
        var next = self
        next.orderClauses.append(OrderByClause(column: column, direction: direction))
        return next
    }

    /// Apply LIMIT and optional OFFSET.
    public func limit(_ n: Int, offset: Int? = nil) -> Select {
        var next = self
        next.limitValue = n
        next.offsetValue = offset
        return next
    }

    /// Add SELECT DISTINCT.
    public func distinct() -> Select {
        var next = self
        next.isDistinct = true
        return next
    }

    // MARK: Build

    /// Render the query to a ``BuiltQuery``, merging any caller-supplied
    /// ``ParamBinding`` values into the bindings dict.
    ///
    /// - Parameter params: Named values for ``Param``s referenced in the
    ///   expression tree.  Pass them as variadic ``ParamBinding`` objects
    ///   produced by ``Param/set(_:)``.
    public func build(params: ParamBinding...) -> BuiltQuery {
        build(params: params)
    }

    /// Array-based build (used internally and by ``Database``).
    public func build(params: [ParamBinding] = []) -> BuiltQuery {
        var ctx = RenderContext()
        var parts: [String] = []

        // WITH / WITH RECURSIVE
        if !ctes.isEmpty {
            let hasRecursive = ctes.contains { $0.recursive != nil }
            let keyword = hasRecursive ? "WITH RECURSIVE" : "WITH"
            let cteSQL = ctes.map { $0.render(into: &ctx) }.joined(separator: ", ")
            parts.append("\(keyword) \(cteSQL)")
        }

        // SELECT [DISTINCT] fields
        let distinctSQL = isDistinct ? "SELECT DISTINCT" : "SELECT"
        let fieldSQL = fields.isEmpty ? "*" : fields.map(\.selectSQL).joined(separator: ", ")
        parts.append("\(distinctSQL) \(fieldSQL)")

        // FROM
        if let fromTable {
            parts.append("FROM \(fromTable.fromSQL)")
        }

        // JOINs
        for j in joins {
            let onSQL = j.on.render(into: &ctx)
            parts.append("\(j.type.sql) \(j.table.fromSQL) ON \(onSQL)")
        }

        // WHERE
        if let whereExpr {
            parts.append("WHERE \(whereExpr.render(into: &ctx))")
        }

        // ORDER BY
        if !orderClauses.isEmpty {
            let orderSQL =
                orderClauses
                .map { "\($0.column.sqlName) \($0.direction.sql)" }
                .joined(separator: ", ")
            parts.append("ORDER BY \(orderSQL)")
        }

        // LIMIT / OFFSET
        if let limitValue {
            parts.append("LIMIT \(limitValue)")
            if let offsetValue {
                parts.append("OFFSET \(offsetValue)")
            }
        }

        let sql = parts.joined(separator: "\n")

        // Merge literal bindings with caller-supplied param bindings.
        var bindings = ctx.bindings
        for pb in params {
            bindings[pb.name] = pb.value
        }

        return BuiltQuery(sql: sql, bindings: bindings)
    }
}

// MARK: - CTE

/// A Common Table Expression for use with ``Select/with(_:)``.
///
/// Set `recursive` to enable `WITH RECURSIVE` and add the recursive term.
public struct CTE: Sendable {
    /// The name referenced in subsequent FROM / JOIN clauses.
    public let name: String
    /// Optional explicit column list.
    public let columns: [String]
    /// The non-recursive (base) SELECT.
    public let base: Select
    /// The recursive SELECT, unioned with `base` using UNION ALL.
    public let recursive: Select?

    /// Creates a non-recursive CTE.
    public init(name: String, columns: [String] = [], base: Select) {
        self.name = name
        self.columns = columns
        self.base = base
        self.recursive = nil
    }

    /// Creates a recursive CTE (`WITH RECURSIVE`).
    public init(name: String, columns: [String] = [], base: Select, recursive: Select) {
        self.name = name
        self.columns = columns
        self.base = base
        self.recursive = recursive
    }

    func render(into ctx: inout RenderContext) -> String {
        let colList = columns.isEmpty ? "" : "(\(columns.joined(separator: ", ")))"
        let baseQuery = base.build(params: [])
        // Merge literal bindings from CTE sub-queries into parent context.
        for (k, v) in baseQuery.bindings { ctx.bindings[k] = v }

        if let rec = recursive {
            let recQuery = rec.build(params: [])
            for (k, v) in recQuery.bindings { ctx.bindings[k] = v }
            return "\(name)\(colList) AS (\n\(baseQuery.sql)\nUNION ALL\n\(recQuery.sql)\n)"
        } else {
            return "\(name)\(colList) AS (\n\(baseQuery.sql)\n)"
        }
    }
}
