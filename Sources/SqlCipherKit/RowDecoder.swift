import Foundation

// MARK: - RowDecoder

/// Decodes a ``Row`` (or an array of ``Row`` values) into any `Decodable` type.
///
/// Column names are matched to the model's `CodingKey.stringValue`.
/// By default the match is case-sensitive; use a custom `CodingKeys` enum to
/// map between your Swift property names and the SQL column names.
///
/// ### Supported column types
///
/// | SQLite `Value`      | Swift types                               |
/// |---------------------|-------------------------------------------|
/// | `.integer`          | `Bool`, `Int`, `Int8/16/32/64`, `UInt8/16/32/64`, `Double`, `Float` |
/// | `.real`             | `Double`, `Float`                         |
/// | `.text`             | `String`, `Date` (via `dateDecodingStrategy`), `UUID` |
/// | `.blob`             | `Data`                                    |
/// | `.null`             | any `Optional<T>`                         |
///
/// ### Date decoding
///
/// ```swift
/// let decoder = RowDecoder()
/// decoder.dateDecodingStrategy = .iso8601
///
/// let users = try db.query("SELECT * FROM users", as: User.self, decoder: decoder)
/// ```
///
/// ### Example
///
/// ```swift
/// struct User: Decodable {
///     let id:    Int
///     let name:  String
///     let email: String
///     let score: Double?
/// }
///
/// let users = try await db.query("SELECT * FROM users", as: User.self)
/// let filtered = try await db.query(
///     Select(.all).from(TableName("users")).where(col("active") == 1),
///     as: User.self
/// )
/// ```
public struct RowDecoder: Sendable {

    // MARK: - Date decoding strategy

    /// Determines how `Date` values stored in a column are decoded.
    public enum DateDecodingStrategy: @unchecked Sendable {

        /// Decodes using `Date`'s own `init(from:)` — reads a `Double`
        /// representing seconds since the reference date (2001-01-01).
        case deferredToDate

        /// Decodes an integer or real column as seconds since Unix epoch (1970-01-01).
        case secondsSince1970

        /// Decodes an integer or real column as milliseconds since Unix epoch.
        case millisecondsSince1970

        /// Decodes a text column using ISO 8601 / RFC 3339 format
        /// (`"2024-01-15T10:30:00Z"`).
        @available(macOS 10.12, iOS 10.0, tvOS 10.0, watchOS 3.0, *)
        case iso8601

        /// Decodes a text column using the given `DateFormatter`.
        case formatted(DateFormatter)

        /// Decodes using a custom closure that receives the raw ``Value`` and
        /// returns a `Date`.
        case custom(@Sendable (Value) throws -> Date)
    }

    // MARK: - Configuration

    /// Strategy used to decode `Date` values.  Defaults to `.deferredToDate`.
    public var dateDecodingStrategy: DateDecodingStrategy = .deferredToDate

    /// Strategy used to decode properties stored as complex column values
    /// (arrays, dictionaries, nested structs).  Defaults to ``ComplexColumnStrategy/json``.
    /// Set to `nil` to throw when the decoder encounters such a column.
    public var complexColumnStrategy: ComplexColumnStrategy? = .json

    // MARK: - Init

    public init() {}

    // MARK: - Decode

    /// Decodes a single `Row` into `T`.
    public func decode<T: Decodable>(_ type: T.Type = T.self, from row: Row) throws -> T {
        try T(
            from: _RowDecoder(
                row: row, codingPath: [], dateStrategy: dateDecodingStrategy,
                complexStrategy: complexColumnStrategy))
    }

    /// Decodes an array of `Row` values into `[T]`.
    public func decode<T: Decodable>(_ type: T.Type = T.self, from rows: [Row]) throws -> [T] {
        try rows.map { try decode(type, from: $0) }
    }
}

// MARK: - Internal Decoder

private struct _RowDecoder: Decoder {
    let row: Row
    let codingPath: [CodingKey]
    let userInfo: [CodingUserInfoKey: Any] = [:]
    let dateStrategy: RowDecoder.DateDecodingStrategy
    let complexStrategy: ComplexColumnStrategy?

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedDecodingContainer<Key> {
        KeyedDecodingContainer(
            _KeyedContainer<Key>(
                row: row, codingPath: codingPath, dateStrategy: dateStrategy,
                complexStrategy: complexStrategy))
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        throw DecodingError.dataCorrupted(
            .init(
                codingPath: codingPath,
                debugDescription: "RowDecoder does not support unkeyed (array) containers. "
                    + "Decode structs with named properties instead."))
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        // Used when decoding a single-column result or a nested Optional.
        // We look for the column whose CodingKey matches the last path element,
        // falling back to column 0.
        let key = codingPath.last?.stringValue
        return _SingleValueContainer(
            value: key.flatMap { row[$0] } ?? row[0],
            codingPath: codingPath,
            dateStrategy: dateStrategy)
    }
}

// MARK: - Keyed Container

private struct _KeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let row: Row
    let codingPath: [CodingKey]
    let dateStrategy: RowDecoder.DateDecodingStrategy
    let complexStrategy: ComplexColumnStrategy?

    var allKeys: [Key] { [] }

    func contains(_ key: Key) -> Bool {
        guard let v = row[key.stringValue] else { return false }
        if case .null = v { return false }
        return true
    }

    // MARK: nil / Optional

    func decodeNil(forKey key: Key) throws -> Bool {
        guard let v = row[key.stringValue] else { return true }
        if case .null = v { return true }
        return false
    }

    // MARK: Primitives

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool { try primitive(key) }
    func decode(_ type: String.Type, forKey key: Key) throws -> String { try primitive(key) }
    func decode(_ type: Double.Type, forKey key: Key) throws -> Double { try primitive(key) }
    func decode(_ type: Float.Type, forKey key: Key) throws -> Float { try primitive(key) }
    func decode(_ type: Int.Type, forKey key: Key) throws -> Int { try primitive(key) }
    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { try primitive(key) }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { try primitive(key) }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { try primitive(key) }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try primitive(key) }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { try primitive(key) }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { try primitive(key) }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { try primitive(key) }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { try primitive(key) }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { try primitive(key) }

    // MARK: Generic Decodable

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        let value = try requireValue(forKey: key)

        // Date
        if type == Date.self {
            let date = try decodeDate(from: value, key: key)
            guard let result = date as? T else { throw mismatch(key, expected: "Date", got: value) }
            return result
        }
        // UUID from text
        if type == UUID.self {
            guard case .text(let s) = value, let uuid = UUID(uuidString: s) else {
                throw mismatch(key, expected: "UUID string", got: value)
            }
            guard let result = uuid as? T else { throw mismatch(key, expected: "UUID", got: value) }
            return result
        }
        // Data from blob
        if type == Data.self {
            guard case .blob(let d) = value else {
                throw mismatch(key, expected: "blob", got: value)
            }
            guard let result = d as? T else { throw mismatch(key, expected: "Data", got: value) }
            return result
        }

        // For TEXT and BLOB columns, try the complex column strategy first.
        // This correctly handles arrays, dictionaries, and nested structs whose
        // data is encoded as JSON (or another format) in the column.
        // If the strategy fails (e.g. a string-backed enum stored as a raw value
        // rather than as JSON), fall through to the nested row-decoder path.
        if let strategy = complexStrategy {
            switch value {
            case .text, .blob:
                do { return try strategy.decode(T.self, from: value) } catch {}
            default: break
            }
        }

        // Nested decode — handles enums with RawRepresentable backing and
        // custom single-scalar Codable types.
        let nested = _RowDecoder(
            row: row,
            codingPath: codingPath + [key],
            dateStrategy: dateStrategy,
            complexStrategy: complexStrategy)
        return try T(from: nested)
    }

    // MARK: Nested / super

    func nestedContainer<NK: CodingKey>(keyedBy type: NK.Type, forKey key: Key) throws
        -> KeyedDecodingContainer<NK>
    {
        KeyedDecodingContainer(
            _KeyedContainer<NK>(
                row: row, codingPath: codingPath + [key], dateStrategy: dateStrategy,
                complexStrategy: complexStrategy))
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        throw DecodingError.dataCorrupted(
            .init(
                codingPath: codingPath + [key],
                debugDescription: "RowDecoder does not support unkeyed nested containers."))
    }

    func superDecoder() throws -> Decoder {
        _RowDecoder(
            row: row, codingPath: codingPath, dateStrategy: dateStrategy,
            complexStrategy: complexStrategy)
    }

    func superDecoder(forKey key: Key) throws -> Decoder {
        _RowDecoder(
            row: row, codingPath: codingPath + [key], dateStrategy: dateStrategy,
            complexStrategy: complexStrategy)
    }

    // MARK: - Private helpers

    private func requireValue(forKey key: Key) throws -> Value {
        guard let v = row[key.stringValue] else {
            throw DecodingError.keyNotFound(
                key,
                .init(
                    codingPath: codingPath,
                    debugDescription: "Column '\(key.stringValue)' not found in row."))
        }
        return v
    }

    private func primitive<T: _RowPrimitive>(_ key: Key) throws -> T {
        let value = try requireValue(forKey: key)
        guard let result = T._decode(from: value) else {
            throw mismatch(key, expected: String(describing: T.self), got: value)
        }
        return result
    }

    private func mismatch(_ key: Key, expected: String, got: Value) -> DecodingError {
        DecodingError.typeMismatch(
            Value.self,
            .init(
                codingPath: codingPath + [key],
                debugDescription:
                    "Expected \(expected) for column '\(key.stringValue)', got \(got)."))
    }

    private func decodeDate(from value: Value, key: Key) throws -> Date {
        switch dateStrategy {
        case .deferredToDate:
            // Date's own Codable encoding is secondsSinceReferenceDate (Double).
            let svc = _SingleValueContainer(
                value: value, codingPath: codingPath + [key], dateStrategy: dateStrategy)
            return try Date(from: _SingleValueDecoder(container: svc))
        case .secondsSince1970:
            guard let d = _doubleFrom(value) else {
                throw mismatch(key, expected: "seconds since 1970 (numeric)", got: value)
            }
            return Date(timeIntervalSince1970: d)
        case .millisecondsSince1970:
            guard let d = _doubleFrom(value) else {
                throw mismatch(key, expected: "milliseconds since 1970 (numeric)", got: value)
            }
            return Date(timeIntervalSince1970: d / 1000)
        case .iso8601:
            guard case .text(let s) = value else {
                throw mismatch(key, expected: "ISO 8601 text", got: value)
            }
            if #available(macOS 10.12, iOS 10.0, tvOS 10.0, watchOS 3.0, *) {
                guard let date = ISO8601DateFormatter().date(from: s) else {
                    throw DecodingError.dataCorrupted(
                        .init(
                            codingPath: codingPath + [key],
                            debugDescription: "Invalid ISO 8601 date string: '\(s)'"))
                }
                return date
            } else {
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: codingPath + [key],
                        debugDescription: "ISO8601DateFormatter unavailable on this platform."))
            }
        case .formatted(let formatter):
            guard case .text(let s) = value else {
                throw mismatch(key, expected: "formatted date text", got: value)
            }
            guard let date = formatter.date(from: s) else {
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: codingPath + [key],
                        debugDescription: "DateFormatter could not parse '\(s)'."))
            }
            return date
        case .custom(let fn):
            return try fn(value)
        }
    }
}

// MARK: - Single-value container

private struct _SingleValueContainer: SingleValueDecodingContainer {
    let value: Value?  // nil means column was absent
    let codingPath: [CodingKey]
    let dateStrategy: RowDecoder.DateDecodingStrategy

    func decodeNil() -> Bool {
        guard let v = value else { return true }
        if case .null = v { return true }
        return false
    }

    func decode(_ type: Bool.Type) throws -> Bool { try prim() }
    func decode(_ type: String.Type) throws -> String { try prim() }
    func decode(_ type: Double.Type) throws -> Double { try prim() }
    func decode(_ type: Float.Type) throws -> Float { try prim() }
    func decode(_ type: Int.Type) throws -> Int { try prim() }
    func decode(_ type: Int8.Type) throws -> Int8 { try prim() }
    func decode(_ type: Int16.Type) throws -> Int16 { try prim() }
    func decode(_ type: Int32.Type) throws -> Int32 { try prim() }
    func decode(_ type: Int64.Type) throws -> Int64 { try prim() }
    func decode(_ type: UInt.Type) throws -> UInt { try prim() }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try prim() }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try prim() }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try prim() }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try prim() }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let v = try requireValue()
        if type == Data.self {
            guard case .blob(let d) = v else { throw mismatch("blob", got: v) }
            guard let result = d as? T else { throw mismatch("Data", got: v) }
            return result
        }
        if type == UUID.self {
            guard case .text(let s) = v, let uuid = UUID(uuidString: s) else {
                throw mismatch("UUID", got: v)
            }
            guard let result = uuid as? T else { throw mismatch("UUID", got: v) }
            return result
        }
        // Fallback: let the type decode itself via a nested decoder.
        let decoder = _SingleValueDecoder(container: self)
        return try T(from: decoder)
    }

    private func prim<T: _RowPrimitive>() throws -> T {
        let v = try requireValue()
        guard let r = T._decode(from: v) else { throw mismatch(String(describing: T.self), got: v) }
        return r
    }

    private func requireValue() throws -> Value {
        guard let v = value else {
            throw DecodingError.valueNotFound(
                Value.self,
                .init(
                    codingPath: codingPath,
                    debugDescription: "Column is absent from this row."))
        }
        if case .null = v {
            throw DecodingError.valueNotFound(
                Value.self,
                .init(
                    codingPath: codingPath,
                    debugDescription:
                        "Column value is NULL; use Optional<T> to handle NULL columns."))
        }
        return v
    }

    private func mismatch(_ expected: String, got: Value) -> DecodingError {
        DecodingError.typeMismatch(
            Value.self,
            .init(
                codingPath: codingPath,
                debugDescription: "Expected \(expected), got \(got)."))
    }
}

// Thin Decoder wrapper used only to call Date(from:) / T(from:)
// via a SingleValueDecodingContainer.
private struct _SingleValueDecoder: Decoder {
    let container: _SingleValueContainer
    var codingPath: [CodingKey] { container.codingPath }
    let userInfo: [CodingUserInfoKey: Any] = [:]
    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        throw DecodingError.dataCorrupted(
            .init(
                codingPath: codingPath,
                debugDescription: "Cannot decode keyed container from a single value."))
    }
    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        throw DecodingError.dataCorrupted(
            .init(
                codingPath: codingPath,
                debugDescription: "Cannot decode unkeyed container from a single value."))
    }
    func singleValueContainer() -> SingleValueDecodingContainer { container }
}

// MARK: - _RowPrimitive protocol (internal conversion helper)

/// Internal protocol mapping Value variants to primitive Swift types.
private protocol _RowPrimitive {
    static func _decode(from value: Value) -> Self?
}

extension Bool: _RowPrimitive {
    static func _decode(from v: Value) -> Bool? {
        switch v {
        case .integer(let i): return i != 0
        case .real(let d): return d != 0
        default: return nil
        }
    }
}
extension String: _RowPrimitive {
    static func _decode(from v: Value) -> String? {
        if case .text(let s) = v { return s }
        return nil
    }
}
extension Double: _RowPrimitive {
    static func _decode(from v: Value) -> Double? {
        switch v {
        case .real(let d): return d
        case .integer(let i): return Double(i)
        default: return nil
        }
    }
}
extension Float: _RowPrimitive {
    static func _decode(from v: Value) -> Float? {
        switch v {
        case .real(let d): return Float(d)
        case .integer(let i): return Float(i)
        default: return nil
        }
    }
}
extension Int: _RowPrimitive {
    static func _decode(from v: Value) -> Int? {
        switch v {
        case .integer(let i): return Int(exactly: i) ?? nil
        case .real(let d): return Int(exactly: d) ?? nil
        default: return nil
        }
    }
}
extension Int8: _RowPrimitive {
    static func _decode(from v: Value) -> Int8? {
        if case .integer(let i) = v { return Int8(exactly: i) }
        return nil
    }
}
extension Int16: _RowPrimitive {
    static func _decode(from v: Value) -> Int16? {
        if case .integer(let i) = v { return Int16(exactly: i) }
        return nil
    }
}
extension Int32: _RowPrimitive {
    static func _decode(from v: Value) -> Int32? {
        if case .integer(let i) = v { return Int32(exactly: i) }
        return nil
    }
}
extension Int64: _RowPrimitive {
    static func _decode(from v: Value) -> Int64? {
        if case .integer(let i) = v { return i }
        return nil
    }
}
extension UInt: _RowPrimitive {
    static func _decode(from v: Value) -> UInt? {
        if case .integer(let i) = v { return UInt(exactly: i) }
        return nil
    }
}
extension UInt8: _RowPrimitive {
    static func _decode(from v: Value) -> UInt8? {
        if case .integer(let i) = v { return UInt8(exactly: i) }
        return nil
    }
}
extension UInt16: _RowPrimitive {
    static func _decode(from v: Value) -> UInt16? {
        if case .integer(let i) = v { return UInt16(exactly: i) }
        return nil
    }
}
extension UInt32: _RowPrimitive {
    static func _decode(from v: Value) -> UInt32? {
        if case .integer(let i) = v { return UInt32(exactly: i) }
        return nil
    }
}
extension UInt64: _RowPrimitive {
    static func _decode(from v: Value) -> UInt64? {
        if case .integer(let i) = v { return UInt64(bitPattern: i) }
        return nil
    }
}

// MARK: - Double helper (used by date decoding)

private func _doubleFrom(_ value: Value) -> Double? {
    switch value {
    case .real(let d): return d
    case .integer(let i): return Double(i)
    default: return nil
    }
}
