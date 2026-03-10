import Foundation

// MARK: - Database: Entity persistence

extension Database {

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
        try _save(record)
    }

    /// Saves an array of `Entity` values inside a single transaction.
    ///
    /// All records are saved atomically: if any one fails the entire batch is
    /// rolled back.  The returned array has the same order as the input, with
    /// auto-increment primary keys filled in where applicable.
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
        guard !records.isEmpty else { return [] }
        try execute("BEGIN")
        var results: [T] = []
        results.reserveCapacity(records.count)
        do {
            for record in records {
                results.append(try _save(record))
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
        return results
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
        var decoder = RowDecoder()
        decoder.complexColumnStrategy = complexColumnStrategy
        let q = Select(.all).from(T.tableName).build()
        let rows = try withConnection { try $0._query(q) }
        return try decoder.decode(T.self, from: rows)
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
        var decoder = RowDecoder()
        decoder.complexColumnStrategy = complexColumnStrategy
        let q = Select(.all).from(T.tableName).where(predicate).build(params: params)
        let rows = try withConnection { try $0._query(q) }
        return try decoder.decode(T.self, from: rows)
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
        var decoder = RowDecoder()
        decoder.complexColumnStrategy = complexColumnStrategy
        let predicate = Expression.compare(ColumnRef(T.primaryKeyName), .eq, .literal(id))
        let q = Select(.all).from(T.tableName).where(predicate).limit(1).build()
        let rows = try withConnection { try $0._query(q) }
        let decoded = try decoder.decode(T.self, from: rows)
        return decoded.first
    }

    // MARK: - Private core

    private func _save<T: Entity>(_ record: T) throws -> T {
        let encoder = RowEncoder()
        encoder.complexColumnStrategy = complexColumnStrategy
        let columns = try encoder.encode(record)

        guard !columns.isEmpty else { throw EntityError.noColumnsToInsert }

        let pkName = T.primaryKeyName
        let pkValue = record[keyPath: T.primaryKey].sqlValue

        switch pkValue {
        case .null:
            return try _insertAutoIncrement(record, columns: columns, pkName: pkName)
        default:
            return try _upsert(record, columns: columns, pkName: pkName)
        }
    }

    /// INSERT without the PK column; write the assigned rowid back to the copy.
    private func _insertAutoIncrement<T: Entity>(
        _ record: T,
        columns: [(key: String, value: Value)],
        pkName: String
    ) throws -> T {
        let insertCols = columns.filter { $0.key != pkName }
        guard !insertCols.isEmpty else { throw EntityError.noColumnsToInsert }

        let colList = insertCols.map { "\"\($0.key)\"" }.joined(separator: ", ")
        let placeholders = Array(repeating: "?", count: insertCols.count).joined(separator: ", ")
        let sql = "INSERT INTO \"\(T.tableName.name)\" (\(colList)) VALUES (\(placeholders))"
        let bindings = insertCols.map { $0.value as any SQLConvertible }

        try withConnection { try $0._execute(sql, bindings: bindings) }

        var copy = record
        let rowid: Int64? = try withConnection {
            try $0._scalarQuery("SELECT last_insert_rowid()", bindings: [], as: Int64.self)
        }
        if let rowid, let assigned = T.ID.from(sqlValue: .integer(rowid)) {
            copy[keyPath: T.primaryKey] = assigned
        }
        return copy
    }

    /// INSERT … ON CONFLICT(pk) DO UPDATE SET …  (true upsert).
    private func _upsert<T: Entity>(
        _ record: T,
        columns: [(key: String, value: Value)],
        pkName: String
    ) throws -> T {
        let updateCols = columns.filter { $0.key != pkName }

        let colList = columns.map { "\"\($0.key)\"" }.joined(separator: ", ")
        let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ", ")
        let bindings = columns.map { $0.value as any SQLConvertible }

        let sql: String
        if updateCols.isEmpty {
            // Only a PK column — treat as idempotent insert.
            sql =
                "INSERT OR IGNORE INTO \"\(T.tableName.name)\" (\(colList)) VALUES (\(placeholders))"
        } else {
            let setClause =
                updateCols
                .map { "\"\($0.key)\" = excluded.\"\($0.key)\"" }
                .joined(separator: ",\n    ")
            sql = """
                INSERT INTO "\(T.tableName.name)" (\(colList))
                VALUES (\(placeholders))
                ON CONFLICT("\(pkName)") DO UPDATE SET
                    \(setClause)
                """
        }

        try withConnection { try $0._execute(sql, bindings: bindings) }
        return record  // PK was already set; copy is identical to input
    }
}
