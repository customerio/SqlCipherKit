// MARK: - Supporting types

/// How a value appears in rendered SQL.
///
/// - `.literal` is an auto-named positional binding (`_0`, `_1`, …) so literals
///   don't appear verbatim in the SQL string — they go through SQLite's normal
///   bind path, keeping the cache key stable.
/// - `.param` refers to a named ``Param`` supplied at execution time.
public enum SQLValue: Sendable {
    case literal(any SQLConvertible)
    case param(String)  // `:name` in rendered SQL
}

// MARK: - ComparisonOp

public enum ComparisonOp: String, Sendable {
    case eq = "="
    case ne = "!="
    case lt = "<"
    case gt = ">"
    case le = "<="
    case ge = ">="
}

// MARK: - Expression

/// A Boolean expression for use in WHERE / JOIN ON clauses.
///
/// Build expressions using the operators and ``ColumnRef`` helpers rather than
/// constructing cases directly:
/// ```swift
/// let expr = col("age") >= Param<Int>("minAge") && col("active") == true
/// ```
public indirect enum Expression: Sendable {
    /// Column compared to a literal or named param (`col = :name`).
    case compare(ColumnRef, ComparisonOp, SQLValue)
    /// Column compared to another column — used in JOIN ON clauses.
    case columnCompare(ColumnRef, ComparisonOp, ColumnRef)
    /// Logical AND of two expressions.
    case and(Expression, Expression)
    /// Logical OR of two expressions (parenthesised for safety).
    case or(Expression, Expression)
    /// Logical negation.
    case not(Expression)
    /// `col IS NULL`
    case isNull(ColumnRef)
    /// `col IS NOT NULL`
    case isNotNull(ColumnRef)
    /// `col BETWEEN lo AND hi`
    case between(ColumnRef, SQLValue, SQLValue)
    /// `col IN (v1, v2, …)` — empty list renders as `1=0` (always false).
    case `in`(ColumnRef, [SQLValue])
    /// `col LIKE pattern`
    case like(ColumnRef, SQLValue)

    // MARK: SQL rendering

    /// Render the expression to a SQL fragment, accumulating any value bindings
    /// into `context`.
    public func render(into context: inout RenderContext) -> String {
        switch self {
        case .compare(let col, let op, let val):
            return "\(col.sqlName) \(op.rawValue) \(context.render(val))"

        case .columnCompare(let lhs, let op, let rhs):
            return "\(lhs.sqlName) \(op.rawValue) \(rhs.sqlName)"

        case .and(let lhs, let rhs):
            return "(\(lhs.render(into: &context)) AND \(rhs.render(into: &context)))"

        case .or(let lhs, let rhs):
            return "(\(lhs.render(into: &context)) OR \(rhs.render(into: &context)))"

        case .not(let expr):
            return "NOT (\(expr.render(into: &context)))"

        case .isNull(let col):
            return "\(col.sqlName) IS NULL"

        case .isNotNull(let col):
            return "\(col.sqlName) IS NOT NULL"

        case .between(let col, let lo, let hi):
            return "\(col.sqlName) BETWEEN \(context.render(lo)) AND \(context.render(hi))"

        case .in(let col, let values):
            if values.isEmpty { return "1 = 0" }
            let placeholders = values.map { context.render($0) }.joined(separator: ", ")
            return "\(col.sqlName) IN (\(placeholders))"

        case .like(let col, let val):
            return "\(col.sqlName) LIKE \(context.render(val))"
        }
    }
}

// MARK: - Operators: ColumnRef vs literal

/// `col("x") == 42`  → `x = :_0`
public func == (lhs: ColumnRef, rhs: some SQLConvertible) -> Expression {
    .compare(lhs, .eq, .literal(rhs))
}

/// `col("x") != 42`  → `x != :_0`
public func != (lhs: ColumnRef, rhs: some SQLConvertible) -> Expression {
    .compare(lhs, .ne, .literal(rhs))
}

/// `col("x") < 42`   → `x < :_0`
public func < (lhs: ColumnRef, rhs: some SQLConvertible) -> Expression {
    .compare(lhs, .lt, .literal(rhs))
}

/// `col("x") > 42`   → `x > :_0`
public func > (lhs: ColumnRef, rhs: some SQLConvertible) -> Expression {
    .compare(lhs, .gt, .literal(rhs))
}

/// `col("x") <= 42`  → `x <= :_0`
public func <= (lhs: ColumnRef, rhs: some SQLConvertible) -> Expression {
    .compare(lhs, .le, .literal(rhs))
}

/// `col("x") >= 42`  → `x >= :_0`
public func >= (lhs: ColumnRef, rhs: some SQLConvertible) -> Expression {
    .compare(lhs, .ge, .literal(rhs))
}

// MARK: - Operators: ColumnRef vs Param<T>

/// `col("x") == Param<String>("name")` → `x = :name`
public func == <T: SQLConvertible>(lhs: ColumnRef, rhs: Param<T>) -> Expression {
    .compare(lhs, .eq, .param(rhs.name))
}

/// `col("x") != Param<String>("name")` → `x != :name`
public func != <T: SQLConvertible>(lhs: ColumnRef, rhs: Param<T>) -> Expression {
    .compare(lhs, .ne, .param(rhs.name))
}

/// `col("x") < Param<Int>("n")` → `x < :n`
public func < <T: SQLConvertible>(lhs: ColumnRef, rhs: Param<T>) -> Expression {
    .compare(lhs, .lt, .param(rhs.name))
}

/// `col("x") > Param<Int>("n")` → `x > :n`
public func > <T: SQLConvertible>(lhs: ColumnRef, rhs: Param<T>) -> Expression {
    .compare(lhs, .gt, .param(rhs.name))
}

/// `col("x") <= Param<Int>("n")` → `x <= :n`
public func <= <T: SQLConvertible>(lhs: ColumnRef, rhs: Param<T>) -> Expression {
    .compare(lhs, .le, .param(rhs.name))
}

/// `col("x") >= Param<Int>("n")` → `x >= :n`
public func >= <T: SQLConvertible>(lhs: ColumnRef, rhs: Param<T>) -> Expression {
    .compare(lhs, .ge, .param(rhs.name))
}

// MARK: - Operators: ColumnRef vs ColumnRef (JOIN ON)

/// `col("a", "id") == col("b", "userId")` → `a.id = b.userId`
public func == (lhs: ColumnRef, rhs: ColumnRef) -> Expression {
    .columnCompare(lhs, .eq, rhs)
}

/// `col("a", "id") != col("b", "userId")` → `a.id != b.userId`
public func != (lhs: ColumnRef, rhs: ColumnRef) -> Expression {
    .columnCompare(lhs, .ne, rhs)
}

// MARK: - Logical operators

/// Combines two expressions with AND.
public func && (lhs: Expression, rhs: Expression) -> Expression { .and(lhs, rhs) }

/// Combines two expressions with OR.
public func || (lhs: Expression, rhs: Expression) -> Expression { .or(lhs, rhs) }

/// Negates an expression.
public prefix func ! (expr: Expression) -> Expression { .not(expr) }

// MARK: - ColumnRef convenience

extension ColumnRef {
    /// `col IS NULL`
    public var isNull: Expression { .isNull(self) }

    /// `col IS NOT NULL`
    public var isNotNull: Expression { .isNotNull(self) }

    /// `col BETWEEN lo AND hi` with literal bounds.
    public func between<T: SQLConvertible>(_ lo: T, _ hi: T) -> Expression {
        .between(self, .literal(lo), .literal(hi))
    }

    /// `col BETWEEN :loParam AND :hiParam` with named param bounds.
    public func between<T: SQLConvertible>(_ lo: Param<T>, _ hi: Param<T>) -> Expression {
        .between(self, .param(lo.name), .param(hi.name))
    }

    /// `col IN (v1, v2, …)` with literal values (variadic).
    public func `in`<T: SQLConvertible>(_ values: T...) -> Expression {
        .in(self, values.map { .literal($0) })
    }

    /// `col IN (v1, v2, …)` with literal values (array).
    public func `in`<T: SQLConvertible>(_ values: [T]) -> Expression {
        .in(self, values.map { .literal($0) })
    }

    /// `col LIKE pattern` with a literal pattern.
    public func like(_ pattern: some SQLConvertible) -> Expression {
        .like(self, .literal(pattern))
    }

    /// `col LIKE :paramName` with a named param pattern.
    public func like<T: SQLConvertible>(_ param: Param<T>) -> Expression {
        .like(self, .param(param.name))
    }
}
