import CSqlCipher
import Foundation

// MARK: - Connection: Entity persistence
//
// The entity operations live on `Connection` so that they can run inside a
// caller's transaction (``Database/transaction(_:)``) or any other
// ``Database/withConnection(_:)`` block.  The `Database` methods of the same
// names in `Database+Entity.swift` forward here.

extension Connection {

    // MARK: - Save

    /// Saves a single `Entity` and returns the (possibly updated) record.
    ///
    /// A record whose primary key is `nil` (`Int?` auto-increment) is inserted
    /// and the assigned rowid is written back to the returned copy.  Any other
    /// record is upserted with `INSERT … ON CONFLICT(pk) DO UPDATE SET …`.
    ///
    /// ```swift
    /// try await db.transaction { conn in
    ///     let order = try conn.save(Order(id: nil, total: 42))
    ///     try conn.save(LineItem(id: nil, orderID: order.id!, sku: "A-1"))
    /// }
    /// ```
    ///
    /// - Throws: ``EntityError`` or ``SqlCipherError``.
    @discardableResult
    public func save<T: Entity>(_ record: T) throws -> T {
        let encoder = RowEncoder()
        encoder.complexColumnStrategy = complexColumnStrategy
        let columns = try encoder.encode(record)

        guard !columns.isEmpty else { throw EntityError.noColumnsToInsert }

        let pkName = T.primaryKeyName
        switch record[keyPath: T.primaryKey].sqlValue {
        case .null:
            return try insertAutoIncrement(record, columns: columns, pkName: pkName)
        default:
            return try upsert(record, columns: columns, pkName: pkName)
        }
    }

    /// Saves an array of `Entity` values atomically.
    ///
    /// The batch runs inside a `SAVEPOINT`, so it commits on its own when
    /// called outside a transaction and nests safely inside one: if any record
    /// fails, every record in the batch is rolled back and the error is
    /// re-thrown, while the enclosing transaction (if any) stays open.
    ///
    /// - Returns: The records in input order, with auto-increment primary keys
    ///   filled in.
    /// - Throws: ``EntityError`` or ``SqlCipherError``.
    @discardableResult
    public func save<T: Entity>(_ records: [T]) throws -> [T] {
        guard !records.isEmpty else { return [] }
        return try savepoint { conn in
            var results: [T] = []
            results.reserveCapacity(records.count)
            for record in records {
                results.append(try conn.save(record))
            }
            return results
        }
    }

    // MARK: - Fetch

    /// Fetches all rows from `T`'s table.
    public func fetch<T: Entity>(_ type: T.Type = T.self) throws -> [T] {
        try decodeEntities(T.self, from: _query(Select(.all).from(T.tableName).build()))
    }

    /// Fetches rows from `T`'s table matching `predicate`.
    ///
    /// - Parameters:
    ///   - type:      The `Entity` type to fetch.
    ///   - predicate: A WHERE ``Expression`` built with ``col(_:)`` and expression operators.
    ///   - params:    Values for any ``Param`` references in `predicate`.
    public func fetch<T: Entity>(
        _ type: T.Type = T.self,
        where predicate: Expression,
        _ params: ParamBinding...
    ) throws -> [T] {
        try _fetch(T.self, where: predicate, params: params)
    }

    /// Fetches the row whose primary key equals `id`, or `nil` if absent.
    public func fetchOne<T: Entity>(_ type: T.Type = T.self, id: T.ID) throws -> T? {
        let q = Select(.all).from(T.tableName).where(primaryKeyPredicate(T.self, id)).limit(1)
            .build()
        return try decodeEntities(T.self, from: _query(q)).first
    }

    // MARK: - Delete

    /// Deletes the row whose primary key equals `id`.
    ///
    /// - Returns: The number of rows deleted (0 or 1).
    @discardableResult
    public func delete<T: Entity>(_ type: T.Type, id: T.ID) throws -> Int {
        try _delete(T.self, where: primaryKeyPredicate(T.self, id), params: [])
    }

    /// Deletes every row from `T`'s table matching `predicate`.
    ///
    /// ```swift
    /// let removed = try await db.delete(Widget.self, where: col("price") < 1.0)
    /// ```
    ///
    /// - Returns: The number of rows deleted.
    @discardableResult
    public func delete<T: Entity>(
        _ type: T.Type,
        where predicate: Expression,
        _ params: ParamBinding...
    ) throws -> Int {
        try _delete(T.self, where: predicate, params: params)
    }

    // MARK: - Savepoints

    /// Runs `body` inside a `SAVEPOINT`, releasing it on success and rolling
    /// back to it if `body` throws.
    ///
    /// Outside a transaction a savepoint behaves like `BEGIN` … `COMMIT`.
    /// Inside one it lets part of the work be undone without abandoning the
    /// rest:
    ///
    /// ```swift
    /// try await db.transaction { conn in
    ///     try conn.save(invoice)
    ///     do {
    ///         try conn.savepoint { try $0.save(optionalAttachment) }
    ///     } catch {
    ///         // The attachment is rolled back; the invoice is kept.
    ///     }
    /// }
    /// ```
    @discardableResult
    public func savepoint<R>(_ body: (borrowing Connection) throws -> R) throws -> R {
        try _execute("SAVEPOINT sqlcipherkit", bindings: [])
        do {
            let result = try body(self)
            try _execute("RELEASE sqlcipherkit", bindings: [])
            return result
        } catch {
            try? _execute("ROLLBACK TO sqlcipherkit", bindings: [])
            try? _execute("RELEASE sqlcipherkit", bindings: [])
            throw error
        }
    }

    // MARK: - Internal array-based entries (used by Database for forwarding)

    func _fetch<T: Entity>(
        _ type: T.Type,
        where predicate: Expression,
        params: [ParamBinding]
    ) throws -> [T] {
        let q = Select(.all).from(T.tableName).where(predicate).build(params: params)
        return try decodeEntities(T.self, from: _query(q))
    }

    func _delete<T: Entity>(
        _ type: T.Type,
        where predicate: Expression,
        params: [ParamBinding]
    ) throws -> Int {
        var ctx = RenderContext()
        let whereSQL = predicate.render(into: &ctx)
        var bindings = ctx.bindings
        for pb in params { bindings[pb.name] = pb.value }
        let q = BuiltQuery(
            sql: "DELETE FROM \"\(T.tableName.name)\" WHERE \(whereSQL)", bindings: bindings)
        try _execute(q)
        return Int(sqlite3_changes(db))
    }

    // MARK: - Private

    private func decodeEntities<T: Entity>(_ type: T.Type, from rows: [Row]) throws -> [T] {
        var decoder = RowDecoder()
        decoder.complexColumnStrategy = complexColumnStrategy
        return try decoder.decode(T.self, from: rows)
    }

    private func primaryKeyPredicate<T: Entity>(_ type: T.Type, _ id: T.ID) -> Expression {
        .compare(ColumnRef(T.primaryKeyName), .eq, .literal(id))
    }

    /// INSERT without the PK column; write the assigned rowid back to the copy.
    private func insertAutoIncrement<T: Entity>(
        _ record: T,
        columns: [(key: String, value: Value)],
        pkName: String
    ) throws -> T {
        let insertCols = columns.filter { $0.key != pkName }
        guard !insertCols.isEmpty else { throw EntityError.noColumnsToInsert }

        let colList = insertCols.map { "\"\($0.key)\"" }.joined(separator: ", ")
        let placeholders = Array(repeating: "?", count: insertCols.count).joined(separator: ", ")
        let sql = "INSERT INTO \"\(T.tableName.name)\" (\(colList)) VALUES (\(placeholders))"
        try _execute(sql, bindings: insertCols.map { $0.value as any SQLConvertible })

        var copy = record
        let rowid = sqlite3_last_insert_rowid(db)
        if let assigned = T.ID.from(sqlValue: .integer(rowid)) {
            copy[keyPath: T.primaryKey] = assigned
        }
        return copy
    }

    /// INSERT … ON CONFLICT(pk) DO UPDATE SET …  (true upsert).
    private func upsert<T: Entity>(
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

        try _execute(sql, bindings: bindings)
        return record  // PK was already set; copy is identical to input
    }
}
