// MARK: - Entity

/// A type that can be persisted to a single database table via ``Database/save(_:)``.
///
/// Adopt `Entity` on any `Codable` struct to get one-line save and fetch semantics:
///
/// ```swift
/// struct User: Entity {
///     static let tableName  = TableName("users")
///     static let primaryKey: WritableKeyPath<User, Int?> & Sendable = \.id
///     var id:    Int?        // nil → SQLite auto-assigns
///     var name:  String
///     var email: String
/// }
///
/// var user = User(id: nil, name: "Alice", email: "alice@example.com")
/// user = try await db.save(user)   // id is now Optional(1)
/// user.name = "Alicia"
/// try await db.save(user)          // updates the row in-place
/// ```
///
/// ### Mapping column names
///
/// By default, Swift property names are used as column names.  Override
/// `primaryKeyName` when the primary key column is named differently from
/// `"id"`, or provide a custom `CodingKeys` enum to rename any column:
///
/// ```swift
/// struct Product: Entity {
///     typealias ID = String
///     static let tableName      = TableName("products")
///     static let primaryKeyName = "product_id"
///     static let primaryKey: WritableKeyPath<Product, String> & Sendable = \.productId
///     var productId: String
///     var title: String
///
///     enum CodingKeys: String, CodingKey {
///         case productId = "product_id"
///         case title
///     }
/// }
/// ```
///
/// ### Auto-increment vs. caller-supplied primary keys
///
/// | `ID` type   | Behaviour when `primaryKey` value… |
/// |-------------|-------------------------------------|
/// | `Int?`      | `nil` → INSERT without PK; SQLite assigns the rowid; the returned copy has the assigned value. |
/// | Any non-optional | Always included in the INSERT; `ON CONFLICT(pk) DO UPDATE SET …` upserts the row. |
///
/// ### Conformance requirements
///
/// - `Self` must be `Codable` and `Sendable`.
/// - `ID` must conform to ``SQLConvertible``, `Hashable`, and `Sendable`.
///   Use `Optional<Int>` (i.e. `Int?`) for auto-increment integer primary keys.
/// - `primaryKey` must be a `WritableKeyPath` from `Self` to `ID`.
public protocol Entity: Codable, Sendable {

    /// The associated Swift type for the primary key value.
    ///
    /// Use `Int?` for auto-increment columns.  For all other key types
    /// (e.g. `String`, `UUID` via a custom conformance, non-optional `Int`)
    /// the value must be supplied before calling ``Database/save(_:)``.
    associatedtype ID: SQLConvertible & Hashable & Sendable

    /// The table this record type maps to.
    static var tableName: TableName { get }

    /// The SQL column name of the primary key.  Defaults to `"id"`.
    ///
    /// Override only when the column name differs from the Swift property name
    /// used in `CodingKeys` — or when the column is named something other than
    /// `"id"` and there is no custom `CodingKeys` to rename it.
    static var primaryKeyName: String { get }

    /// A `WritableKeyPath` pointing to the primary key property.
    ///
    /// `WritableKeyPath` is required so that ``Database/save(_:)`` can write
    /// the SQLite-assigned rowid back to the returned copy when `ID` is `Int?`
    /// and the incoming value is `nil`.
    ///
    /// Declare with an explicit `& Sendable` type annotation so a `static let`
    /// can be used instead of a computed property:
    /// ```swift
    /// static let primaryKey: WritableKeyPath<User, Int?> & Sendable = \.id
    /// ```
    static var primaryKey: WritableKeyPath<Self, ID> & Sendable { get }
}

// MARK: - Default implementations

extension Entity {
    /// Defaults to `"id"`.
    public static var primaryKeyName: String { "id" }
}

// MARK: - EntityError

/// Errors thrown by the ``Entity`` persistence layer.
public enum EntityError: Error, CustomStringConvertible {

    /// The encoder produced no columns — the record cannot be saved.
    case noColumnsToInsert

    /// The record has no non-primary-key columns; an upsert would be a no-op.
    case noDataColumns

    public var description: String {
        switch self {
        case .noColumnsToInsert:
            return "Entity: no columns were produced by the encoder. "
                + "Ensure the type conforms to Encodable with at least one property."
        case .noDataColumns:
            return "Entity: the record has only a primary key column. "
                + "There are no other columns to upsert."
        }
    }
}
