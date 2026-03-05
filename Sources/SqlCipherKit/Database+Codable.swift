import Foundation

// MARK: - Database: Codable query overloads
//
// Typed `query<T: Decodable>` overloads that run a SELECT and decode each
// result row into a Swift model using ``RowDecoder``.
//
// ### Example
// ```swift
// struct User: Decodable { let id: Int; let name: String }
//
// // Raw SQL
// let users = try await db.query("SELECT * FROM users", as: User.self)
//
// // QueryBuilder
// let users = try await db.query(Select(.all).from(TableName("users")), as: User.self)
// ```

extension Database {

    // MARK: - Raw SQL

    /// Executes a raw-SQL SELECT and decodes each row into `T`.
    ///
    /// - Parameters:
    ///   - sql:      The SQL text, optionally containing `?` placeholders.
    ///   - bindings: Values to bind to each `?` in order.
    ///   - type:     The `Decodable` type to decode each row into.
    ///   - decoder:  The ``RowDecoder`` to use.  Defaults to a fresh instance.
    public func query<T: Decodable>(
        _ sql: String,
        _ bindings: any SQLConvertible...,
        as type: T.Type = T.self,
        decoder: RowDecoder = RowDecoder()
    ) throws -> [T] {
        let rows = try withConnection { try $0._query(sql, bindings: bindings) }
        return try decoder.decode(T.self, from: rows)
    }

    // MARK: - BuiltQuery

    /// Executes a ``BuiltQuery`` and decodes each row into `T`.
    ///
    /// - Parameters:
    ///   - query:   A pre-built query.
    ///   - type:    The `Decodable` type to decode each row into.
    ///   - decoder: The ``RowDecoder`` to use.  Defaults to a fresh instance.
    public func query<T: Decodable>(
        _ query: BuiltQuery,
        as type: T.Type = T.self,
        decoder: RowDecoder = RowDecoder()
    ) throws -> [T] {
        let rows = try withConnection { try $0._query(query) }
        return try decoder.decode(T.self, from: rows)
    }

    // MARK: - Select (variadic params)

    /// Builds a ``Select`` query and decodes each row into `T`.
    ///
    /// - Parameters:
    ///   - select:  The `Select` query to build.
    ///   - params:  Variadic ``ParamBinding`` values.
    ///   - type:    The `Decodable` type to decode each row into.
    ///   - decoder: The ``RowDecoder`` to use.  Defaults to a fresh instance.
    public func query<T: Decodable>(
        _ select: Select,
        _ params: ParamBinding...,
        as type: T.Type = T.self,
        decoder: RowDecoder = RowDecoder()
    ) throws -> [T] {
        let q = select.build(params: params)
        let rows = try withConnection { try $0._query(q) }
        return try decoder.decode(T.self, from: rows)
    }

    // MARK: - Select (dictionary params)

    /// Builds a ``Select`` query (dict params) and decodes each row into `T`.
    ///
    /// - Parameters:
    ///   - select:  The `Select` query to build.
    ///   - params:  Named bindings dictionary.
    ///   - type:    The `Decodable` type to decode each row into.
    ///   - decoder: The ``RowDecoder`` to use.  Defaults to a fresh instance.
    public func query<T: Decodable>(
        _ select: Select,
        params: [String: any SQLConvertible],
        as type: T.Type = T.self,
        decoder: RowDecoder = RowDecoder()
    ) throws -> [T] {
        let q = select.build(params: params.map { ParamBinding(name: $0.key, value: $0.value) })
        let rows = try withConnection { try $0._query(q) }
        return try decoder.decode(T.self, from: rows)
    }
}
