import Foundation
import Testing

@testable import SqlCipherKit

// MARK: - Helpers

private func tempPath() -> String {
    NSTemporaryDirectory() + "qb_test_\(Int.random(in: 1_000_000...9_999_999)).db"
}

// MARK: - TableName tests

@Suite("TableName")
struct TableNameTests {

    @Test("plain table name")
    func plainName() {
        let t = TableName("users")
        #expect(t.qualifier == "users")
        #expect(t.fromSQL == "users")
    }

    @Test("table name with alias")
    func withAlias() {
        let t = TableName("users").alias("u")
        #expect(t.qualifier == "u")
        #expect(t.fromSQL == "users AS u")
    }
}

// MARK: - ColumnRef tests

@Suite("ColumnRef")
struct ColumnRefTests {

    @Test("plain column")
    func plain() {
        let c = col("name")
        #expect(c.sqlName == "name")
        #expect(c.selectSQL == "name")
    }

    @Test("column with table qualifier")
    func qualified() {
        let t = TableName("users").alias("u")
        let c = col("name").of(t)
        #expect(c.sqlName == "u.name")
        #expect(c.selectSQL == "u.name")
    }

    @Test("column with alias")
    func aliased() {
        let c = col("user_name").alias("name")
        #expect(c.sqlName == "user_name")
        #expect(c.selectSQL == "user_name AS name")
    }

    @Test("wildcard")
    func wildcard() {
        #expect(ColumnRef.all.sqlName == "*")
    }
}

// MARK: - Expression rendering tests

@Suite("Expression")
struct ExpressionTests {

    @Test("literal equality renders named placeholder")
    func literalEq() {
        var ctx = RenderContext()
        let expr = col("age") == 42
        let sql = expr.render(into: &ctx)
        #expect(sql == "age = :_0")
        #expect((ctx.bindings["_0"] as? Int) == 42)
    }

    @Test("param equality uses param name")
    func paramEq() {
        let p = Param<String>("username")
        var ctx = RenderContext()
        let expr = col("name") == p
        let sql = expr.render(into: &ctx)
        #expect(sql == "name = :username")
        #expect(ctx.bindings.isEmpty)  // param values resolved at build time
    }

    @Test("and expression")
    func andExpr() {
        var ctx = RenderContext()
        let expr = col("a") == 1 && col("b") == 2
        let sql = expr.render(into: &ctx)
        #expect(sql == "(a = :_0 AND b = :_1)")
    }

    @Test("or expression")
    func orExpr() {
        var ctx = RenderContext()
        let expr = col("a") == 1 || col("b") == 2
        let sql = expr.render(into: &ctx)
        #expect(sql == "(a = :_0 OR b = :_1)")
    }

    @Test("not expression")
    func notExpr() {
        var ctx = RenderContext()
        let expr = !(col("active") == true)
        let sql = expr.render(into: &ctx)
        #expect(sql == "NOT (active = :_0)")
    }

    @Test("isNull / isNotNull")
    func nullChecks() {
        var ctx = RenderContext()
        #expect(col("x").isNull.render(into: &ctx) == "x IS NULL")
        #expect(col("x").isNotNull.render(into: &ctx) == "x IS NOT NULL")
    }

    @Test("between literals")
    func betweenLiterals() {
        var ctx = RenderContext()
        let sql = col("score").between(1, 100).render(into: &ctx)
        #expect(sql == "score BETWEEN :_0 AND :_1")
        #expect((ctx.bindings["_0"] as? Int) == 1)
        #expect((ctx.bindings["_1"] as? Int) == 100)
    }

    @Test("in values")
    func inValues() {
        var ctx = RenderContext()
        let sql = col("status").in(1, 2, 3).render(into: &ctx)
        #expect(sql == "status IN (:_0, :_1, :_2)")
    }

    @Test("in empty list renders always-false")
    func inEmpty() {
        var ctx = RenderContext()
        let sql = col("status").in([Int]()).render(into: &ctx)
        #expect(sql == "1 = 0")
    }

    @Test("like literal")
    func likeLiteral() {
        var ctx = RenderContext()
        let sql = col("name").like("Al%").render(into: &ctx)
        #expect(sql == "name LIKE :_0")
    }

    @Test("column compare (JOIN ON)")
    func columnCompare() {
        let users = TableName("users")
        let orders = TableName("orders")
        let u = users.alias("u")
        let o = orders.alias("o")
        var ctx = RenderContext()
        let sql = (col("id").of(u) == col("user_id").of(o)).render(into: &ctx)
        #expect(sql == "u.id = o.user_id")
        #expect(ctx.bindings.isEmpty)
    }
}

// MARK: - Select rendering tests

@Suite("Select rendering")
struct SelectRenderingTests {

    @Test("simple select all")
    func simpleSelectAll() {
        let q = Select(.all).from("users").build()
        #expect(q.sql == "SELECT *\nFROM users")
        #expect(q.bindings.isEmpty)
    }

    @Test("select with columns and where")
    func selectColumnsWhere() {
        let q = Select(col("id"), col("name"))
            .from("users")
            .where(col("active") == true)
            .build()
        #expect(q.sql.contains("SELECT id, name"))
        #expect(q.sql.contains("WHERE active = :_0"))
        let active = q.bindings["_0"]
        #expect((active as? Bool) == true)
    }

    @Test("distinct")
    func distinct() {
        let q = Select(col("country")).from("users").distinct().build()
        #expect(q.sql.hasPrefix("SELECT DISTINCT"))
    }

    @Test("order by ascending (default) and descending")
    func orderBy() {
        let q = Select(.all)
            .from("scores")
            .orderBy(col("score"), .descending)
            .orderBy(col("name"))
            .build()
        #expect(q.sql.contains("ORDER BY score DESC, name ASC"))
    }

    @Test("limit only")
    func limitOnly() {
        let q = Select(.all).from("items").limit(10).build()
        #expect(q.sql.contains("LIMIT 10"))
        #expect(!q.sql.contains("OFFSET"))
    }

    @Test("limit with offset")
    func limitOffset() {
        let q = Select(.all).from("items").limit(10, offset: 20).build()
        #expect(q.sql.contains("LIMIT 10"))
        #expect(q.sql.contains("OFFSET 20"))
    }

    @Test("join clause")
    func join() {
        let users = TableName("users")
        let orders = TableName("orders")
        let u = users.alias("u")
        let o = orders.alias("o")
        let name = col("name")
        let total = col("total")
        let q = Select(name.of(u), total.of(o))
            .from(u)
            .join(o, on: col("u", "id") == col("o", "user_id"))
            .build()
        #expect(q.sql.contains("INNER JOIN orders AS o ON u.id = o.user_id"))
    }

    @Test("left join")
    func leftJoin() {
        let users = TableName("users")
        let orders = TableName("orders")
        let q = Select(.all)
            .from(users)
            .join(orders, type: .left, on: col("id").of(users) == col("user_id").of(orders))
            .build()
        #expect(q.sql.contains("LEFT JOIN"))
    }

    @Test("named param in build")
    func namedParam() {
        let minAge = Param<Int>("minAge")
        let q = Select(.all)
            .from("users")
            .where(col("age") >= minAge)
            .build(params: minAge.set(18))
        #expect(q.sql.contains("WHERE age >= :minAge"))
        #expect((q.bindings["minAge"] as? Int) == 18)
    }

    @Test("same SQL for different literal values")
    func literalCacheKey() {
        let q1 = Select(.all).from("items").where(col("id") == 1).build()
        let q2 = Select(.all).from("items").where(col("id") == 2).build()
        // SQL strings are identical; only bindings differ.
        #expect(q1.sql == q2.sql)
        #expect((q1.bindings["_0"] as? Int) == 1)
        #expect((q2.bindings["_0"] as? Int) == 2)
    }
}

// MARK: - Param tests

@Suite("Param")
struct ParamTests {

    @Test("set returns binding with correct name and value")
    func setBinding() {
        let p = Param<String>("username")
        let b = p.set("alice")
        #expect(b.name == "username")
        #expect((b.value as? String) == "alice")
    }
}

// MARK: - Integration tests (QueryBuilder → real database)

@Suite("QueryBuilder integration")
struct QueryBuilderIntegrationTests {

    @Test("insert and select via BuiltQuery")
    func insertSelect() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let db = try Database(path: path, key: "qb-test")
        try await db.execute("CREATE TABLE fruits (id INTEGER PRIMARY KEY, name TEXT, qty INTEGER)")
        try await db.execute("INSERT INTO fruits VALUES (1, 'apple', 5)")
        try await db.execute("INSERT INTO fruits VALUES (2, 'banana', 3)")

        let q = Select(.all).from("fruits").where(col("qty") > 2).orderBy(col("name")).build()
        let rows = try await db.query(q)
        #expect(rows.count == 2)
        #expect(rows[0]["name"] == .text("apple"))
        #expect(rows[1]["name"] == .text("banana"))
    }

    @Test("named param reuse hits statement cache")
    func namedParamReuse() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let db = try Database(path: path, key: "qb-namedparam")
        try await db.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, score REAL)")
        for i in 1...5 {
            try await db.execute("INSERT INTO items VALUES (?, ?)", i, Double(i) * 1.5)
        }

        let minScore = Param<Double>("minScore")
        let template = Select(.all).from("items").where(col("score") >= minScore)

        let low = try await db.query(template, minScore.set(1.0))
        let high = try await db.query(template, minScore.set(5.0))

        #expect(low.count == 5)
        #expect(high.count == 2)
    }

    @Test("scalar query via Select")
    func scalarSelect() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let db = try Database(path: path, key: "qb-scalar")
        try await db.execute("CREATE TABLE nums (n INTEGER)")
        try await db.execute("INSERT INTO nums VALUES (10)")
        try await db.execute("INSERT INTO nums VALUES (20)")

        let q = Select(col("SUM(n)")).from("nums")
        let total = try await db.scalarQuery(q, as: Int.self)
        #expect(total == 30)
    }

    @Test("recursive CTE — hierarchy walk")
    func recursiveCTE() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let db = try Database(path: path, key: "qb-cte")
        try await db.execute(
            """
                CREATE TABLE categories (
                    id INTEGER PRIMARY KEY,
                    parent_id INTEGER,
                    name TEXT
                )
            """)
        // root → 1, child → 2, grandchild → 3
        try await db.execute("INSERT INTO categories VALUES (1, NULL, 'root')")
        try await db.execute("INSERT INTO categories VALUES (2, 1,    'child')")
        try await db.execute("INSERT INTO categories VALUES (3, 2,    'grandchild')")

        let rootId = Param<Int>("rootId")

        let categories = TableName("categories")
        let ancestors = TableName("ancestors")
        let c = categories.alias("c")
        let a = ancestors.alias("a")

        let base = Select(col("id"), col("parent_id"), col("name"))
            .from(categories)
            .where(col("id") == rootId)

        let rec = Select(col("id").of(c), col("parent_id").of(c), col("name").of(c))
            .from(c)
            .join(a, on: col("parent_id").of(c) == col("id").of(a))

        let cte = CTE(
            name: "ancestors",
            columns: ["id", "parent_id", "name"],
            base: base,
            recursive: rec)

        let q = Select(.all).from(ancestors).with(cte)
        let rows = try await db.query(q, rootId.set(1))

        #expect(rows.count == 3)
        let names = rows.compactMap { row -> String? in
            if case .text(let n) = row["name"] { return n }
            return nil
        }.sorted()
        #expect(names == ["child", "grandchild", "root"])
    }
}
