import Foundation

// MARK: - Database: TableRecord persistence

extension Database {

    /// Saves a single `TableRecord` to the database and returns the (possibly updated) record.
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
    /// - Throws: ``TableRecordError`` or ``SqlCipherError``.
    @discardableResult
    public func save<T: TableRecord>(_ record: T) throws -> T {
        try _save(record)
    }

    /// Saves an array of `TableRecord` values inside a single transaction.
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
    /// - Throws: ``TableRecordError`` or ``SqlCipherError``.
    @discardableResult
    public func save<T: TableRecord>(_ records: [T]) throws -> [T] {
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

    // MARK: - Private core

    private func _save<T: TableRecord>(_ record: T) throws -> T {
        let encoder = RowEncoder()
        let columns = try encoder.encode(record)

        guard !columns.isEmpty else { throw TableRecordError.noColumnsToInsert }

        let pkName  = T.primaryKeyName
        let pkValue = record[keyPath: T.primaryKey].sqlValue

        switch pkValue {
        case .null:
            return try _insertAutoIncrement(record, columns: columns, pkName: pkName)
        default:
            return try _upsert(record, columns: columns, pkName: pkName)
        }
    }

    /// INSERT without the PK column; write the assigned rowid back to the copy.
    private func _insertAutoIncrement<T: TableRecord>(
        _ record: T,
        columns: [(key: String, value: Value)],
        pkName: String
    ) throws -> T {
        let insertCols = columns.filter { $0.key != pkName }
        guard !insertCols.isEmpty else { throw TableRecordError.noColumnsToInsert }

        let colList      = insertCols.map { "\"\($0.key)\"" }.joined(separator: ", ")
        let placeholders = Array(repeating: "?", count: insertCols.count).joined(separator: ", ")
        let sql          = "INSERT INTO \"\(T.tableName.name)\" (\(colList)) VALUES (\(placeholders))"
        let bindings     = insertCols.map { $0.value as any SQLConvertible }

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
    private func _upsert<T: TableRecord>(
        _ record: T,
        columns: [(key: String, value: Value)],
        pkName: String
    ) throws -> T {
        let updateCols = columns.filter { $0.key != pkName }

        let colList      = columns.map { "\"\($0.key)\"" }.joined(separator: ", ")
        let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ", ")
        let bindings     = columns.map { $0.value as any SQLConvertible }

        let sql: String
        if updateCols.isEmpty {
            // Only a PK column — treat as idempotent insert.
            sql = "INSERT OR IGNORE INTO \"\(T.tableName.name)\" (\(colList)) VALUES (\(placeholders))"
        } else {
            let setClause = updateCols
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
        return record   // PK was already set; copy is identical to input
    }
}
