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

// MARK: - ColumnDefinition rendering tests

@Suite("ColumnDefinition")
struct ColumnDefinitionTests {

    @Test("basic column renders type")
    func basicType() {
        let def = ColumnDefinition("score", .real)
        #expect(def.render() == "score REAL")
    }

    @Test("autoIncrement constraint")
    func autoIncrement() {
        let def = ColumnDefinition("id", .integer, .autoIncrement)
        #expect(def.render() == "id INTEGER PRIMARY KEY AUTOINCREMENT")
    }

    @Test("multiple constraints")
    func multipleConstraints() {
        let def = ColumnDefinition("email", .text, .notNull, .unique)
        #expect(def.render() == "email TEXT NOT NULL UNIQUE")
    }

    @Test("default integer value")
    func defaultInt() {
        let def = ColumnDefinition("qty", .integer, .notNull, .default(0))
        #expect(def.render() == "qty INTEGER NOT NULL DEFAULT 0")
    }

    @Test("default text value is quoted")
    func defaultText() {
        let def = ColumnDefinition("status", .text, .default("active"))
        #expect(def.render() == "status TEXT DEFAULT 'active'")
    }

    @Test("default text with single quote is escaped")
    func defaultTextEscaped() {
        let def = ColumnDefinition("label", .text, .default("it's here"))
        #expect(def.render() == "label TEXT DEFAULT 'it''s here'")
    }

    @Test("check constraint")
    func checkConstraint() {
        let def = ColumnDefinition("score", .real, .check("score >= 0 AND score <= 100"))
        #expect(def.render() == "score REAL CHECK (score >= 0 AND score <= 100)")
    }

    @Test("foreign key reference")
    func foreignKey() {
        let groups = TableName("groups")
        let def = ColumnDefinition("group_id", .integer, .references(groups, column: "id"))
        #expect(def.render() == "group_id INTEGER REFERENCES groups(id)")
    }
}

// MARK: - CreateTable rendering tests

@Suite("CreateTable")
struct CreateTableTests {

    @Test("IF NOT EXISTS is default")
    func ifNotExists() {
        let users = TableName("users")
        let q = CreateTable(users)
            .column("id", .integer, .autoIncrement)
            .build()
        #expect(q.sql.hasPrefix("CREATE TABLE IF NOT EXISTS users"))
        #expect(q.bindings.isEmpty)
    }

    @Test("without IF NOT EXISTS guard")
    func withoutGuard() {
        let t = TableName("tmp")
        let q = CreateTable(t, ifNotExists: false)
            .column("n", .integer)
            .build()
        #expect(q.sql.hasPrefix("CREATE TABLE tmp"))
        #expect(!q.sql.contains("IF NOT EXISTS"))
    }

    @Test("all column types render")
    func allTypes() {
        let t = TableName("types")
        let q = CreateTable(t)
            .column("a", .integer)
            .column("b", .text)
            .column("c", .real)
            .column("d", .blob)
            .column("e", .numeric)
            .build()
        for ty in ["INTEGER", "TEXT", "REAL", "BLOB", "NUMERIC"] {
            #expect(q.sql.contains(ty))
        }
    }

    @Test("accepts pre-built ColumnDefinition")
    func prebuiltDef() {
        let t = TableName("items")
        let def = ColumnDefinition("price", .real, .notNull, .default(0.0))
        let q = CreateTable(t).column(def).build()
        #expect(q.sql.contains("price REAL NOT NULL DEFAULT 0.0"))
    }
}

// MARK: - AlterTable rendering tests

@Suite("AlterTable")
struct AlterTableTests {

    @Test("rename table")
    func renameTable() {
        let old = TableName("users")
        let q = AlterTable(old, renameTo: "people").build()
        #expect(q.sql == "ALTER TABLE users RENAME TO people")
        #expect(q.bindings.isEmpty)
    }

    @Test("rename column")
    func renameColumn() {
        let t = TableName("users")
        let q = AlterTable(t, renameColumn: "email", to: "email_address").build()
        #expect(q.sql == "ALTER TABLE users RENAME COLUMN email TO email_address")
    }

    @Test("add column")
    func addColumn() {
        let t = TableName("users")
        let q = AlterTable(t, addColumn: "bio", .text, .notNull).build()
        #expect(q.sql == "ALTER TABLE users ADD COLUMN bio TEXT NOT NULL")
    }

    @Test("add column with prebuilt definition")
    func addColumnPrebuilt() {
        let t = TableName("users")
        let def = ColumnDefinition("score", .real, .default(0.0))
        let q = AlterTable(t, addColumn: def).build()
        #expect(q.sql == "ALTER TABLE users ADD COLUMN score REAL DEFAULT 0.0")
    }

    @Test("drop column")
    func dropColumn() {
        let t = TableName("users")
        let q = AlterTable(t, dropColumn: "legacy_field").build()
        #expect(q.sql == "ALTER TABLE users DROP COLUMN legacy_field")
        #expect(q.bindings.isEmpty)
    }
}

// MARK: - DropTable rendering tests

@Suite("DropTable")
struct DropTableTests {

    @Test("IF EXISTS is default")
    func ifExistsDefault() {
        let q = DropTable(TableName("users")).build()
        #expect(q.sql == "DROP TABLE IF EXISTS users")
        #expect(q.bindings.isEmpty)
    }

    @Test("without IF EXISTS guard")
    func withoutGuard() {
        let q = DropTable(TableName("users"), ifExists: false).build()
        #expect(q.sql == "DROP TABLE users")
    }
}

// MARK: - CreateIndex rendering tests

@Suite("CreateIndex")
struct CreateIndexTests {

    @Test("simple single-column index")
    func simpleIndex() {
        let users = TableName("users")
        let q = CreateIndex("idx_users_email", on: users)
            .column("email")
            .build()
        #expect(q.sql == "CREATE INDEX IF NOT EXISTS idx_users_email ON users (email)")
        #expect(q.bindings.isEmpty)
    }

    @Test("unique index")
    func uniqueIndex() {
        let users = TableName("users")
        let q = CreateIndex("idx_users_email", on: users, unique: true)
            .column("email")
            .build()
        #expect(q.sql == "CREATE UNIQUE INDEX IF NOT EXISTS idx_users_email ON users (email)")
    }

    @Test("composite index")
    func compositeIndex() {
        let users = TableName("users")
        let q = CreateIndex("idx_users_name_email", on: users)
            .column("name")
            .column("email")
            .build()
        #expect(q.sql == "CREATE INDEX IF NOT EXISTS idx_users_name_email ON users (name, email)")
    }

    @Test("column with explicit sort direction")
    func sortDirection() {
        let users = TableName("users")
        let q = CreateIndex("idx_users_score", on: users)
            .column("score", .descending)
            .column("name", .ascending)
            .build()
        #expect(
            q.sql == "CREATE INDEX IF NOT EXISTS idx_users_score ON users (score DESC, name ASC)")
    }

    @Test("without IF NOT EXISTS guard")
    func withoutGuard() {
        let users = TableName("users")
        let q = CreateIndex("idx_users_email", on: users, ifNotExists: false)
            .column("email")
            .build()
        #expect(q.sql == "CREATE INDEX idx_users_email ON users (email)")
    }
}

// MARK: - DropIndex rendering tests

@Suite("DropIndex")
struct DropIndexTests {

    @Test("IF EXISTS is default")
    func ifExistsDefault() {
        let q = DropIndex("idx_users_email").build()
        #expect(q.sql == "DROP INDEX IF EXISTS idx_users_email")
        #expect(q.bindings.isEmpty)
    }

    @Test("without IF EXISTS guard")
    func withoutGuard() {
        let q = DropIndex("idx_users_email", ifExists: false).build()
        #expect(q.sql == "DROP INDEX idx_users_email")
    }
}

// MARK: - Insert rendering tests

@Suite("Insert")
struct InsertTests {

    @Test("literal values use positional placeholders")
    func literals() {
        let users = TableName("users")
        let q = Insert(into: users)
            .set(col("name"), to: "Alice")
            .set(col("score"), to: 9.5)
            .build()
        #expect(q.sql == "INSERT INTO users (name, score) VALUES (:_0, :_1)")
        #expect((q.bindings["_0"] as? String) == "Alice")
        #expect((q.bindings["_1"] as? Double) == 9.5)
    }

    @Test("named params stay constant across calls")
    func namedParams() {
        let users = TableName("users")
        let nameParam = Param<String>("name")
        let scoreParam = Param<Double>("score")

        let insert = Insert(into: users)
            .set(col("name"), to: nameParam)
            .set(col("score"), to: scoreParam)

        let q1 = insert.build(params: nameParam.set("Alice"), scoreParam.set(9.5))
        let q2 = insert.build(params: nameParam.set("Bob"), scoreParam.set(7.0))

        // SQL is identical — good for the statement cache
        #expect(q1.sql == q2.sql)
        #expect(q1.sql == "INSERT INTO users (name, score) VALUES (:name, :score)")
        #expect((q1.bindings["name"] as? String) == "Alice")
        #expect((q2.bindings["name"] as? String) == "Bob")
    }

    @Test("OR IGNORE conflict resolution")
    func orIgnore() {
        let t = TableName("items")
        let q = Insert(into: t, onConflict: .ignore)
            .set(col("id"), to: 1)
            .build()
        #expect(q.sql.hasPrefix("INSERT OR IGNORE INTO items"))
    }

    @Test("OR REPLACE conflict resolution")
    func orReplace() {
        let t = TableName("items")
        let q = Insert(into: t, onConflict: .replace)
            .set(col("id"), to: 1)
            .build()
        #expect(q.sql.hasPrefix("INSERT OR REPLACE INTO items"))
    }
}

// MARK: - Update rendering tests

@Suite("Update")
struct UpdateTests {

    @Test("single column with literal")
    func singleLiteral() {
        let users = TableName("users")
        let id = col("id")
        let q = Update(users)
            .set(col("name"), to: "Alice")
            .where(id == 1)
            .build()
        #expect(q.sql.contains("UPDATE users"))
        #expect(q.sql.contains("SET name = :_0"))
        #expect(q.sql.contains("WHERE id = :_1"))
        #expect((q.bindings["_0"] as? String) == "Alice")
        #expect((q.bindings["_1"] as? Int) == 1)
    }

    @Test("named params - same SQL different values")
    func namedParams() {
        let users = TableName("users")
        let nameParam = Param<String>("name")
        let idParam = Param<Int>("id")

        let update = Update(users)
            .set(col("name"), to: nameParam)
            .where(col("id") == idParam)

        let q1 = update.build(params: nameParam.set("Alice"), idParam.set(1))
        let q2 = update.build(params: nameParam.set("Bob"), idParam.set(2))

        #expect(q1.sql == q2.sql)
        #expect(q1.sql == "UPDATE users\nSET name = :name\nWHERE id = :id")
        #expect((q1.bindings["name"] as? String) == "Alice")
        #expect((q2.bindings["name"] as? String) == "Bob")
    }

    @Test("update without WHERE renders correctly")
    func noWhere() {
        let t = TableName("settings")
        let q = Update(t).set(col("value"), to: "dark").build()
        #expect(!q.sql.contains("WHERE"))
    }

    @Test("multiple SET columns")
    func multipleColumns() {
        let t = TableName("users")
        let q = Update(t)
            .set(col("name"), to: "Alice")
            .set(col("score"), to: 10.0)
            .build()
        #expect(q.sql.contains("name = :_0, score = :_1"))
    }
}

// MARK: - DDL/DML integration tests

@Suite("DDL and DML integration")
struct DDLDMLIntegrationTests {

    @Test("CreateTable and Insert round-trip")
    func createAndInsert() async throws {
        let path = NSTemporaryDirectory() + "ddl_test_\(Int.random(in: 1_000_000...9_999_999)).db"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let db = try Database(path: path, key: "ddl-test")
        let users = TableName("users")
        let name = col("name")
        let email = col("email")

        try await db.execute(
            CreateTable(users)
                .column("id", .integer, .autoIncrement)
                .column("name", .text, .notNull)
                .column("email", .text, .notNull, .unique)
        )

        let nameParam = Param<String>("name")
        let emailParam = Param<String>("email")

        let insert = Insert(into: users)
            .set(name, to: nameParam)
            .set(email, to: emailParam)

        try await db.execute(insert, nameParam.set("Alice"), emailParam.set("alice@example.com"))
        try await db.execute(insert, nameParam.set("Bob"), emailParam.set("bob@example.com"))

        let rows = try await db.query(Select(.all).from(users))
        #expect(rows.count == 2)
        #expect(rows[0]["name"] == .text("Alice"))
        #expect(rows[1]["name"] == .text("Bob"))
    }

    @Test("Update with named params modifies correct row")
    func updateNamedParam() async throws {
        let path = NSTemporaryDirectory() + "upd_test_\(Int.random(in: 1_000_000...9_999_999)).db"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let db = try Database(path: path, key: "upd-test")
        let items = TableName("items")

        try await db.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, label TEXT, qty INTEGER)")
        try await db.execute("INSERT INTO items VALUES (1, 'apple',  5)")
        try await db.execute("INSERT INTO items VALUES (2, 'banana', 3)")

        let qtyParam = Param<Int>("qty")
        let idParam = Param<Int>("id")

        let update = Update(items)
            .set(col("qty"), to: qtyParam)
            .where(col("id") == idParam)

        try await db.execute(update, qtyParam.set(10), idParam.set(1))
        try await db.execute(update, qtyParam.set(7), idParam.set(2))

        let appleQty = try await db.scalarQuery(
            Select(col("qty")).from(items).where(col("id") == 1), as: Int.self)
        let bananaQty = try await db.scalarQuery(
            Select(col("qty")).from(items).where(col("id") == 2), as: Int.self)

        #expect(appleQty == 10)
        #expect(bananaQty == 7)
    }

    @Test("AlterTable adds column visible in subsequent query")
    func alterAddColumn() async throws {
        let path = NSTemporaryDirectory() + "alt_test_\(Int.random(in: 1_000_000...9_999_999)).db"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let db = try Database(path: path, key: "alt-test")
        let users = TableName("users")

        try await db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)")
        try await db.execute("INSERT INTO users VALUES (1, 'Alice')")

        try await db.execute(AlterTable(users, addColumn: "score", .real, .default(0.0)))

        let rows = try await db.query(Select(.all).from(users))
        #expect(rows.count == 1)
        #expect(rows[0]["score"] == .real(0.0))
    }

    @Test("AlterTable drops column")
    func alterDropColumn() async throws {
        let path = NSTemporaryDirectory() + "alt_drop_\(Int.random(in: 1_000_000...9_999_999)).db"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let db = try Database(path: path, key: "alt-drop-test")
        let users = TableName("users")

        try await db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, legacy TEXT)")
        try await db.execute("INSERT INTO users VALUES (1, 'Alice', 'old')")

        try await db.execute(AlterTable(users, dropColumn: "legacy"))

        // 'legacy' column should be gone; only id and name remain.
        let rows = try await db.query(Select(.all).from(users))
        #expect(rows.count == 1)
        #expect(rows[0]["name"] == .text("Alice"))
        #expect(rows[0]["legacy"] == nil)
    }

    @Test("Insert OR IGNORE skips duplicate")
    func insertOrIgnore() async throws {
        let path = NSTemporaryDirectory() + "ins_test_\(Int.random(in: 1_000_000...9_999_999)).db"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let db = try Database(path: path, key: "ins-test")
        let tokens = TableName("tokens")

        try await db.execute(
            CreateTable(tokens)
                .column("value", .text, .primaryKey)
        )

        let insert = Insert(into: tokens, onConflict: .ignore)
            .set(col("value"), to: Param<String>("v"))
        let v = Param<String>("v")

        try await db.execute(insert, v.set("tok-abc"))
        try await db.execute(insert, v.set("tok-abc"))  // duplicate — ignored, no throw

        let count = try await db.scalarQuery(
            Select(col("COUNT(*)")).from(tokens), as: Int.self)
        #expect(count == 1)
    }

    @Test("DropTable removes table")
    func dropTable() async throws {
        let path = NSTemporaryDirectory() + "droptbl_\(Int.random(in: 1_000_000...9_999_999)).db"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let db = try Database(path: path, key: "drop-test")
        try await db.execute("CREATE TABLE tmp (id INTEGER)")

        try await db.execute(DropTable(TableName("tmp")))

        let exists = try await db.scalarQuery(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='tmp'",
            as: Int.self)
        #expect(exists == 0)
    }

    @Test("DropTable IF EXISTS is a no-op on missing table")
    func dropTableIfExists() async throws {
        let path = NSTemporaryDirectory() + "droptbl2_\(Int.random(in: 1_000_000...9_999_999)).db"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let db = try Database(path: path, key: "drop-test2")
        // Should not throw even though the table doesn't exist.
        try await db.execute(DropTable(TableName("nonexistent")))
    }

    @Test("CreateIndex and DropIndex round-trip")
    func createAndDropIndex() async throws {
        let path = NSTemporaryDirectory() + "idx_\(Int.random(in: 1_000_000...9_999_999)).db"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let db = try Database(path: path, key: "idx-test")
        let users = TableName("users")
        try await db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT, name TEXT)")

        try await db.execute(
            CreateIndex("idx_users_email", on: users, unique: true)
                .column("email")
        )

        let idxExists = try await db.scalarQuery(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name='idx_users_email'",
            as: Int.self)
        #expect(idxExists == 1)

        try await db.execute(DropIndex("idx_users_email"))

        let idxGone = try await db.scalarQuery(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name='idx_users_email'",
            as: Int.self)
        #expect(idxGone == 0)
    }

    @Test("unique index enforces uniqueness")
    func uniqueIndexEnforced() async throws {
        let path = NSTemporaryDirectory() + "uqidx_\(Int.random(in: 1_000_000...9_999_999)).db"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let db = try Database(path: path, key: "uqidx-test")
        let users = TableName("users")
        try await db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT)")

        try await db.execute(
            CreateIndex("idx_users_email", on: users, unique: true)
                .column("email")
        )

        try await db.execute("INSERT INTO users VALUES (1, 'a@b.com')")

        var didThrow = false
        do {
            try await db.execute("INSERT INTO users VALUES (2, 'a@b.com')")
        } catch {
            didThrow = true
        }
        #expect(didThrow, "Unique index should have rejected duplicate email")
    }
}
