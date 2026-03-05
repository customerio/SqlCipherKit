// MARK: - Insert

/// Builds an `INSERT` statement using a fluent column-assignment API.
///
/// Like ``Select``, `Insert` separates the query template from runtime values,
/// so the same `Insert` object can be reused with different ``Param`` values
/// and still hit the statement cache.
///
/// ```swift
/// let users = TableName("users")
/// let id    = col("id")
/// let name  = col("name")
/// let email = col("email")
///
/// // With named params (template reusable):
/// let nameParam  = Param<String>("name")
/// let emailParam = Param<String>("email")
///
/// let insert = Insert(into: users)
///     .set(name,  to: nameParam)
///     .set(email, to: emailParam)
///
/// try await db.execute(insert, nameParam.set("Alice"), emailParam.set("alice@example.com"))
/// try await db.execute(insert, nameParam.set("Bob"),   emailParam.set("bob@example.com"))
///
/// // With literals (one-shot):
/// try await db.execute(
///     Insert(into: users).set(name, to: "Carol").set(email, to: "carol@example.com")
/// )
/// ```
public struct Insert: Sendable {

    // MARK: - Conflict resolution

    /// The `ON CONFLICT` algorithm for this insert.
    public enum ConflictResolution: String, Sendable {
        case rollback = "OR ROLLBACK"
        case abort    = "OR ABORT"
        case fail     = "OR FAIL"
        case ignore   = "OR IGNORE"
        case replace  = "OR REPLACE"
    }

    // MARK: - Storage

    private let table: TableName
    private var assignments: [(column: ColumnRef, value: SQLValue)]
    private let onConflict: ConflictResolution?

    // MARK: - Initialiser

    public init(into table: TableName, onConflict: ConflictResolution? = nil) {
        self.table = table
        self.assignments = []
        self.onConflict = onConflict
    }

    // MARK: - Fluent setters

    /// Binds `column` to a literal value at build time.
    ///
    /// The value is auto-named (`:_0`, `:_1`, …) so the SQL string stays
    /// constant across calls with different literals.
    public func set(_ column: ColumnRef, to value: some SQLConvertible) -> Insert {
        var next = self
        next.assignments.append((column, .literal(value)))
        return next
    }

    /// Binds `column` to a named ``Param``, resolved at execution time.
    public func set<T: SQLConvertible>(_ column: ColumnRef, to param: Param<T>) -> Insert {
        var next = self
        next.assignments.append((column, .param(param.name)))
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
        let cols = assignments.map { $0.column.name }.joined(separator: ", ")
        let vals = assignments.map { ctx.render($0.value) }.joined(separator: ", ")
        let conflict = onConflict.map { " \($0.rawValue)" } ?? ""
        let sql = "INSERT\(conflict) INTO \(table.name) (\(cols)) VALUES (\(vals))"
        var bindings = ctx.bindings
        for pb in params { bindings[pb.name] = pb.value }
        return BuiltQuery(sql: sql, bindings: bindings)
    }
}
