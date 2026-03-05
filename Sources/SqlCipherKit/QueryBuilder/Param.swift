// MARK: - Param

/// A typed, named query parameter.
///
/// `Param<T>` carries a name and a generic type so that the value you bind at
/// query-execution time is checked against `T` by the compiler.  Use it both
/// in the query template (as the RHS of comparisons) and at the call site (via
/// ``set(_:)``):
///
/// ```swift
/// let nameParam  = Param<String>("name")
/// let minScore   = Param<Double>("minScore")
///
/// // Build the template once — SQL string stays constant across executions.
/// let topUsers = Select(.all)
///     .from(TableName("users"))
///     .where(col("name") == nameParam && col("score") >= minScore)
///
/// // Execute with different values — hits the statement cache every time.
/// let batch1 = try await db.query(topUsers, nameParam.set("Alice"), minScore.set(8.5))
/// let batch2 = try await db.query(topUsers, nameParam.set("Bob"),   minScore.set(7.0))
/// ```
///
/// You can also pass a plain `[String: any SQLConvertible]` dict using the
/// `params:` labelled overload when you prefer a more dynamic approach.
public struct Param<T: SQLConvertible>: Sendable {

    /// The name without any prefix — matched to `:name` in the rendered SQL.
    public let name: String

    public init(_ name: String) {
        self.name = name
    }

    /// Creates a typed binding for this parameter.
    ///
    /// Pass the result to ``Database/query(_:_:)-7bq3s`` (or the `execute` /
    /// `scalarQuery` equivalents):
    /// ```swift
    /// db.query(select, nameParam.set("Alice"), ageParam.set(30))
    /// ```
    public func set(_ value: T) -> ParamBinding {
        ParamBinding(name: name, value: value)
    }
}

// MARK: - ParamBinding

/// A concrete, type-erased name–value pair produced by ``Param/set(_:)``.
///
/// At the call site `T` is already checked, so the binding can be stored and
/// passed as `any SQLConvertible` without further type information.
public struct ParamBinding: Sendable {
    let name: String
    let value: any SQLConvertible
}
