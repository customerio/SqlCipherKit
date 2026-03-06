// MARK: - Database: QueryBuilder overloads
//
// Overloads for ``BuiltQuery``, ``Select``, ``Insert``, ``Update``,
// and DDL builders (``CreateTable``, ``AlterTable``, etc.).

extension Database {

    // MARK: - BuiltQuery

    /// Executes a pre-built query that produces no result rows.
    public func execute(_ query: BuiltQuery) throws {
        try withConnection { try $0._execute(query) }
    }

    /// Executes a pre-built query and returns all matching rows.
    public func query(_ query: BuiltQuery) throws -> [Row] {
        try withConnection { try $0._query(query) }
    }

    /// Executes a pre-built query and returns the first column of the first row.
    public func scalarQuery<T: SQLConvertible>(
        _ query: BuiltQuery,
        as type: T.Type = T.self
    ) throws -> T? {
        try withConnection { try $0._scalarQuery(query, as: T.self) }
    }

    // MARK: - Select: execute

    /// Builds and executes a ``Select`` with variadic ``ParamBinding`` values.
    public func execute(_ select: Select, _ params: ParamBinding...) throws {
        let q = select.build(params: params)
        try withConnection { try $0._execute(q) }
    }

    /// Builds and executes a ``Select`` with a bindings dictionary.
    public func execute(_ select: Select, params: [String: any SQLConvertible]) throws {
        let q = select.build(params: params.map { ParamBinding(name: $0.key, value: $0.value) })
        try withConnection { try $0._execute(q) }
    }

    // MARK: - Select: query

    /// Builds and queries a ``Select`` with variadic ``ParamBinding`` values.
    public func query(_ select: Select, _ params: ParamBinding...) throws -> [Row] {
        let q = select.build(params: params)
        return try withConnection { try $0._query(q) }
    }

    /// Builds and queries a ``Select`` with a bindings dictionary.
    public func query(_ select: Select, params: [String: any SQLConvertible]) throws -> [Row] {
        let q = select.build(params: params.map { ParamBinding(name: $0.key, value: $0.value) })
        return try withConnection { try $0._query(q) }
    }

    // MARK: - Select: scalarQuery

    /// Builds a ``Select`` query and returns its first column as `T`.
    public func scalarQuery<T: SQLConvertible>(
        _ select: Select,
        _ params: ParamBinding...,
        as type: T.Type = T.self
    ) throws -> T? {
        let q = select.build(params: params)
        return try withConnection { try $0._scalarQuery(q, as: T.self) }
    }

    /// Builds a ``Select`` query (dict params) and returns its first column as `T`.
    public func scalarQuery<T: SQLConvertible>(
        _ select: Select,
        params: [String: any SQLConvertible],
        as type: T.Type = T.self
    ) throws -> T? {
        let q = select.build(params: params.map { ParamBinding(name: $0.key, value: $0.value) })
        return try withConnection { try $0._scalarQuery(q, as: T.self) }
    }

    // MARK: - Insert

    /// Builds and executes an ``Insert`` with variadic ``ParamBinding`` values.
    public func execute(_ insert: Insert, _ params: ParamBinding...) throws {
        try withConnection { try $0._execute(insert.build(params: params)) }
    }

    // MARK: - Update

    /// Builds and executes an ``Update`` with variadic ``ParamBinding`` values.
    public func execute(_ update: Update, _ params: ParamBinding...) throws {
        try withConnection { try $0._execute(update.build(params: params)) }
    }

    // MARK: - DDL

    /// Builds and executes a ``CreateTable`` statement.
    public func execute(_ create: CreateTable) throws {
        try withConnection { try $0._execute(create.build()) }
    }

    /// Builds and executes an ``AlterTable`` statement.
    public func execute(_ alter: AlterTable) throws {
        try withConnection { try $0._execute(alter.build()) }
    }

    /// Builds and executes a ``DropTable`` statement.
    public func execute(_ drop: DropTable) throws {
        try withConnection { try $0._execute(drop.build()) }
    }

    /// Builds and executes a ``CreateIndex`` statement.
    public func execute(_ create: CreateIndex) throws {
        try withConnection { try $0._execute(create.build()) }
    }

    /// Builds and executes a ``DropIndex`` statement.
    public func execute(_ drop: DropIndex) throws {
        try withConnection { try $0._execute(drop.build()) }
    }
}
