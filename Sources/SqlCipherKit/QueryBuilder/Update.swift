// MARK: - Update

/// Builds an `UPDATE` statement using a fluent column-assignment API.
///
/// Like ``Insert``, `Update` separates the query template from runtime values
/// so named-param templates can be reused across calls without recompiling.
///
/// ```swift
/// let users = TableName("users")
/// let name  = col("name")
/// let id    = col("id")
///
/// let nameParam = Param<String>("name")
/// let idParam   = Param<Int>("id")
///
/// let update = Update(users)
///     .set(name, to: nameParam)
///     .where(id == idParam)
///
/// try await db.execute(update, nameParam.set("Alice"), idParam.set(1))
/// try await db.execute(update, nameParam.set("Bob"),   idParam.set(2))
/// ```
public struct Update: Sendable {

    // MARK: - Storage

    private let table: TableName
    private var assignments: [(column: ColumnRef, value: SQLValue)]
    private var whereExpr: Expression?

    // MARK: - Initialiser

    public init(_ table: TableName) {
        self.table = table
        self.assignments = []
        self.whereExpr = nil
    }

    // MARK: - Fluent setters

    /// Sets `column` to a literal value at build time.
    public func set(_ column: ColumnRef, to value: some SQLConvertible) -> Update {
        var next = self
        next.assignments.append((column, .literal(value)))
        return next
    }

    /// Sets `column` to a named ``Param``, resolved at execution time.
    public func set<T: SQLConvertible>(_ column: ColumnRef, to param: Param<T>) -> Update {
        var next = self
        next.assignments.append((column, .param(param.name)))
        return next
    }

    // MARK: - WHERE

    /// Filters which rows are updated.
    public func `where`(_ expr: Expression) -> Update {
        var next = self
        next.whereExpr = expr
        return next
    }

    // MARK: - Build

    /// Builds the statement, merging any caller-supplied ``ParamBinding`` values.
    public func build(params: ParamBinding...) -> BuiltQuery {
        build(params: params)
    }

    /// Array-based build (used internally and by ``Database``).
    public func build(params: [ParamBinding] = []) -> BuiltQuery {
        var ctx = RenderContext()
        let setClause = assignments
            .map { "\($0.column.name) = \(ctx.render($0.value))" }
            .joined(separator: ", ")
        var parts = ["UPDATE \(table.name)", "SET \(setClause)"]
        if let expr = whereExpr {
            parts.append("WHERE \(expr.render(into: &ctx))")
        }
        var bindings = ctx.bindings
        for pb in params { bindings[pb.name] = pb.value }
        return BuiltQuery(sql: parts.joined(separator: "\n"), bindings: bindings)
    }
}
