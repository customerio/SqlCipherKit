import Foundation

// MARK: - Database: Entity persistence
//
// One-shot entity operations.  Each forwards to the ``Connection`` method of
// the same name; to combine several in one transaction, call those methods
// inside ``Database/transaction(_:)`` instead.

extension Database {

    // MARK: - Save

    /// Saves a single `Entity` to the database and returns the (possibly updated) record.
    ///
    /// The exact SQL depends on the primary key value at the time of the call:
    ///
    /// **Non-null PK — upsert in place:**
    /// ```sql
    /// INSERT INTO "tableName" ("col1", "col2", …)
    /// VALUES (?, ?, …)
    /// ON CONFLICT("pkCol") DO UPDATE SET
    ///     "col1" = excluded."col1",
    ///     "col2" = excluded."col2", …
    /// ```
    ///
    /// **Null PK (`Int?` auto-increment) — plain insert:**
    /// ```sql
    /// INSERT INTO "tableName" ("col1", "col2", …) VALUES (?, ?, …)
    /// ```
    /// After a successful insert the assigned rowid is written back to the
    /// returned copy via the `WritableKeyPath`.
    ///
    /// - Parameter record: The record to save.
    /// - Returns: A copy of `record` with its primary key set to the assigned
    ///   value (relevant only for auto-increment `Int?` PKs; otherwise
    ///   identical to the input).
    /// - Throws: ``EntityError`` or ``SqlCipherError``.
    @discardableResult
    public func save<T: Entity>(_ record: T) throws -> T {
        try withConnection { try $0.save(record) }
    }

    /// Saves an array of `Entity` values atomically.
    ///
    /// If any one record fails the entire batch is rolled back.  The returned
    /// array has the same order as the input, with auto-increment primary keys
    /// filled in where applicable.
    ///
    /// ```swift
    /// let saved = try await db.save([alice, bob, carol])
    /// ```
    ///
    /// - Parameter records: The records to save.
    /// - Returns: A copy of `records` with primary keys updated as needed.
    /// - Throws: ``EntityError`` or ``SqlCipherError``.
    @discardableResult
    public func save<T: Entity>(_ records: [T]) throws -> [T] {
        try withConnection { try $0.save(records) }
    }

    // MARK: - Fetch

    /// Fetches all rows from `T`'s table, decoded as `[T]`.
    ///
    /// ```swift
    /// let allWidgets = try await db.fetch(Widget.self)
    /// ```
    ///
    /// - Parameter type: The `Entity` type to fetch.  Can be inferred from context.
    public func fetch<T: Entity>(_ type: T.Type = T.self) throws -> [T] {
        try withConnection { try $0.fetch(T.self) }
    }

    /// Fetches rows matching `predicate` from `T`'s table.
    ///
    /// Use ``col(_:)`` and the expression operators to build the predicate, and
    /// ``Param`` for values you want to supply at the call site rather than
    /// baking into the query template:
    ///
    /// ```swift
    /// // Literal values
    /// let cheap = try await db.fetch(Widget.self, where: col("price") < 5.0)
    ///
    /// // Named param — same SQL template, different values
    /// let minPrice = Param<Double>("minPrice")
    /// let template = col("price") >= minPrice
    /// let expensive = try await db.fetch(Widget.self, where: template, minPrice.set(100.0))
    /// ```
    ///
    /// - Parameters:
    ///   - type:      The `Entity` type to fetch.
    ///   - predicate: A WHERE ``Expression`` built with ``col(_:)`` and expression operators.
    ///   - params:    Variadic ``ParamBinding`` values for any ``Param`` references in `predicate`.
    public func fetch<T: Entity>(
        _ type: T.Type = T.self,
        where predicate: Expression,
        _ params: ParamBinding...
    ) throws -> [T] {
        try withConnection { try $0._fetch(T.self, where: predicate, params: params) }
    }

    /// Fetches the single row whose primary key equals `id`, or `nil` if absent.
    ///
    /// ```swift
    /// if let widget = try await db.fetchOne(Widget.self, id: 42) {
    ///     print(widget.name)
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - type: The `Entity` type to fetch.  Can be inferred from context.
    ///   - id:   The primary key value to look up.
    public func fetchOne<T: Entity>(_ type: T.Type = T.self, id: T.ID) throws -> T? {
        try withConnection { try $0.fetchOne(T.self, id: id) }
    }

    // MARK: - Delete

    /// Deletes the row whose primary key equals `id`.
    ///
    /// ```swift
    /// try await db.delete(Widget.self, id: 42)
    /// ```
    ///
    /// - Returns: The number of rows deleted (0 or 1).
    @discardableResult
    public func delete<T: Entity>(_ type: T.Type, id: T.ID) throws -> Int {
        try withConnection { try $0.delete(T.self, id: id) }
    }

    /// Deletes every row from `T`'s table matching `predicate`.
    ///
    /// ```swift
    /// let removed = try await db.delete(Widget.self, where: col("price") < 1.0)
    /// ```
    ///
    /// - Parameters:
    ///   - type:      The `Entity` type whose table to delete from.
    ///   - predicate: A WHERE ``Expression``.
    ///   - params:    Variadic ``ParamBinding`` values for any ``Param`` references in `predicate`.
    /// - Returns: The number of rows deleted.
    @discardableResult
    public func delete<T: Entity>(
        _ type: T.Type,
        where predicate: Expression,
        _ params: ParamBinding...
    ) throws -> Int {
        try withConnection { try $0._delete(T.self, where: predicate, params: params) }
    }

    // MARK: - Transactions

    /// Runs `body` inside a transaction, committing when it returns and
    /// rolling back if it throws.
    ///
    /// Every ``Connection`` method is available inside the body, including the
    /// entity operations, so raw SQL, query builders, and entities can be
    /// combined atomically:
    ///
    /// ```swift
    /// let order = try await db.transaction { conn in
    ///     let order = try conn.save(Order(id: nil, customer: "Alice"))
    ///     try conn.save(items.map { LineItem(id: nil, orderID: order.id!, sku: $0) })
    ///     try conn.execute("UPDATE customers SET orders = orders + 1 WHERE name = ?", "Alice")
    ///     return order
    /// }
    /// ```
    ///
    /// Reads inside the body see the body's own uncommitted writes.  The body
    /// is synchronous and runs on the actor, so no other operation on this
    /// `Database` can interleave with it.  Do not issue `BEGIN`, `COMMIT`, or
    /// `ROLLBACK` inside the body; use ``Connection/savepoint(_:)`` for a
    /// nested, independently undoable step.
    ///
    /// - Parameter body: The work to perform atomically.
    /// - Returns: Whatever `body` returns.
    /// - Throws: Any error thrown by `body` (after rolling back), or a
    ///   ``SqlCipherError`` if the transaction cannot begin or commit.
    @discardableResult
    public func transaction<R>(_ body: (borrowing Connection) throws -> R) throws -> R {
        try withConnection { conn in
            try conn._execute("BEGIN", bindings: [])
            do {
                let result = try body(conn)
                try conn._execute("COMMIT", bindings: [])
                return result
            } catch {
                try? conn._execute("ROLLBACK", bindings: [])
                throw error
            }
        }
    }
}
