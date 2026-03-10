import Foundation

// MARK: - RowEncoder

/// Encodes any `Encodable` value into an ordered array of `(column, Value)`
/// pairs suitable for building SQL `INSERT` / `UPDATE` statements.
///
/// Column order matches the order Swift's `Codable` synthesis visits
/// properties — i.e. declaration order — which keeps generated SQL stable.
///
/// ### Supported property types
///
/// | Swift type                        | SQLite `Value`                       |
/// |-----------------------------------|--------------------------------------|
/// | `Bool`                            | `.integer` (0 or 1)                 |
/// | `Int`, `Int8/16/32/64`            | `.integer`                           |
/// | `UInt`, `UInt8/16/32/64`          | `.integer`                           |
/// | `Double`, `Float`                 | `.real`                              |
/// | `String`                          | `.text`                              |
/// | `Data`                            | `.blob`                              |
/// | `Date`                            | via `dateEncodingStrategy`           |
/// | `UUID`                            | `.text` (UUID string)               |
/// | `Optional<T>` where T above       | `.null` when `nil`                  |
/// | `enum` with `String`/`Int` backing | `.text` / `.integer`               |
///
/// ### Example
///
/// ```swift
/// struct Product: Encodable {
///     let sku: String
///     let name: String
///     let price: Double
/// }
///
/// let cols = try RowEncoder().encode(Product(sku: "A1", name: "Widget", price: 9.99))
/// // [("sku", .text("A1")), ("name", .text("Widget")), ("price", .real(9.99))]
/// ```
public final class RowEncoder {

    // MARK: - Date encoding strategy

    /// Determines how `Date` values are encoded into a column.
    public enum DateEncodingStrategy: @unchecked Sendable {

        /// Encodes using `Date`'s own `encode(to:)` — stores a `Double`
        /// representing seconds since the reference date (2001-01-01).
        case deferredToDate

        /// Stores seconds since Unix epoch (1970-01-01) as a real value.
        case secondsSince1970

        /// Stores milliseconds since Unix epoch as a real value.
        case millisecondsSince1970

        /// Stores an ISO 8601 / RFC 3339 text string.
        @available(macOS 10.12, iOS 10.0, tvOS 10.0, watchOS 3.0, *)
        case iso8601

        /// Stores a text string formatted by the supplied `DateFormatter`.
        case formatted(DateFormatter)

        /// Stores whatever `Value` the custom closure returns.
        case custom(@Sendable (Date) -> Value)
    }

    // MARK: - Configuration

    /// Strategy used to encode `Date` values.  Defaults to `.deferredToDate`.
    public var dateEncodingStrategy: DateEncodingStrategy = .deferredToDate

    /// Strategy used to encode properties that cannot be mapped to a scalar
    /// SQL value (arrays, dictionaries, nested structs).  Defaults to ``ComplexColumnStrategy/json``.
    /// Set to `nil` to throw an error when such a property is encountered.
    public var complexColumnStrategy: ComplexColumnStrategy? = .json

    // MARK: - Init

    public init() {}

    // MARK: - Encode

    /// Encodes `value` into an ordered array of (column name, SQL value) pairs.
    ///
    /// - Parameter value: Any top-level `Encodable` struct or class.
    /// - Returns: Column name / value pairs in the order the encoder visited them.
    /// - Throws: `EncodingError` if the structure cannot be mapped to flat columns.
    public func encode<T: Encodable>(_ value: T) throws -> [(key: String, value: Value)] {
        let storage = _EncoderStorage()
        let encoder = _RowEncoder(
            storage: storage, codingPath: [], dateStrategy: dateEncodingStrategy,
            complexStrategy: complexColumnStrategy)
        try value.encode(to: encoder)
        return storage.columns
    }
}

// MARK: - Internal storage

/// Accumulates column name / value pairs in insertion order.
private final class _EncoderStorage {
    var columns: [(key: String, value: Value)] = []

    func append(key: String, value: Value) {
        columns.append((key: key, value: value))
    }
}

// MARK: - _RowEncoder : Encoder

private struct _RowEncoder: Encoder {
    let storage: _EncoderStorage
    let codingPath: [CodingKey]
    let userInfo: [CodingUserInfoKey: Any] = [:]
    let dateStrategy: RowEncoder.DateEncodingStrategy
    let complexStrategy: ComplexColumnStrategy?

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        KeyedEncodingContainer(
            _KeyedContainer<Key>(
                storage: storage, codingPath: codingPath, dateStrategy: dateStrategy,
                complexStrategy: complexStrategy))
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        _ThrowingUnkeyedContainer(codingPath: codingPath)
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        // Used when encoding an Optional wrapper that itself encodes to a single value.
        _SingleValueContainer(
            storage: storage, codingPath: codingPath, dateStrategy: dateStrategy,
            complexStrategy: complexStrategy)
    }
}

// MARK: - _KeyedContainer

private struct _KeyedContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let storage: _EncoderStorage
    let codingPath: [CodingKey]
    let dateStrategy: RowEncoder.DateEncodingStrategy
    let complexStrategy: ComplexColumnStrategy?

    // MARK: nil / Optional

    mutating func encodeNil(forKey key: Key) throws {
        storage.append(key: key.stringValue, value: .null)
    }

    /// Override: the default `encodeIfPresent` overloads silently drop `nil`
    /// values (JSON convention — absent key ≡ nil).  For SQL we always want an
    /// explicit `.null` in the column list.
    ///
    /// We must override BOTH the generic and every primitive-typed variant
    /// because the Codable synthesiser calls the most specific overload.

    mutating func encodeIfPresent(_ value: Bool?, forKey key: Key) throws {
        if let v = value { try encode(v, forKey: key) } else { try encodeNil(forKey: key) }
    }
    mutating func encodeIfPresent(_ value: String?, forKey key: Key) throws {
        if let v = value { try encode(v, forKey: key) } else { try encodeNil(forKey: key) }
    }
    mutating func encodeIfPresent(_ value: Double?, forKey key: Key) throws {
        if let v = value { try encode(v, forKey: key) } else { try encodeNil(forKey: key) }
    }
    mutating func encodeIfPresent(_ value: Float?, forKey key: Key) throws {
        if let v = value { try encode(v, forKey: key) } else { try encodeNil(forKey: key) }
    }
    mutating func encodeIfPresent(_ value: Int?, forKey key: Key) throws {
        if let v = value { try encode(v, forKey: key) } else { try encodeNil(forKey: key) }
    }
    mutating func encodeIfPresent(_ value: Int8?, forKey key: Key) throws {
        if let v = value { try encode(v, forKey: key) } else { try encodeNil(forKey: key) }
    }
    mutating func encodeIfPresent(_ value: Int16?, forKey key: Key) throws {
        if let v = value { try encode(v, forKey: key) } else { try encodeNil(forKey: key) }
    }
    mutating func encodeIfPresent(_ value: Int32?, forKey key: Key) throws {
        if let v = value { try encode(v, forKey: key) } else { try encodeNil(forKey: key) }
    }
    mutating func encodeIfPresent(_ value: Int64?, forKey key: Key) throws {
        if let v = value { try encode(v, forKey: key) } else { try encodeNil(forKey: key) }
    }
    mutating func encodeIfPresent(_ value: UInt?, forKey key: Key) throws {
        if let v = value { try encode(v, forKey: key) } else { try encodeNil(forKey: key) }
    }
    mutating func encodeIfPresent(_ value: UInt8?, forKey key: Key) throws {
        if let v = value { try encode(v, forKey: key) } else { try encodeNil(forKey: key) }
    }
    mutating func encodeIfPresent(_ value: UInt16?, forKey key: Key) throws {
        if let v = value { try encode(v, forKey: key) } else { try encodeNil(forKey: key) }
    }
    mutating func encodeIfPresent(_ value: UInt32?, forKey key: Key) throws {
        if let v = value { try encode(v, forKey: key) } else { try encodeNil(forKey: key) }
    }
    mutating func encodeIfPresent(_ value: UInt64?, forKey key: Key) throws {
        if let v = value { try encode(v, forKey: key) } else { try encodeNil(forKey: key) }
    }
    mutating func encodeIfPresent<T: Encodable>(_ value: T?, forKey key: Key) throws {
        if let v = value { try encode(v, forKey: key) } else { try encodeNil(forKey: key) }
    }

    // MARK: Primitives

    mutating func encode(_ v: Bool, forKey key: Key) throws {
        storage.append(key: key.stringValue, value: v.sqlValue)
    }
    mutating func encode(_ v: String, forKey key: Key) throws {
        storage.append(key: key.stringValue, value: v.sqlValue)
    }
    mutating func encode(_ v: Double, forKey key: Key) throws {
        storage.append(key: key.stringValue, value: v.sqlValue)
    }
    mutating func encode(_ v: Float, forKey key: Key) throws {
        storage.append(key: key.stringValue, value: Float(v).sqlValue)
    }
    mutating func encode(_ v: Int, forKey key: Key) throws {
        storage.append(key: key.stringValue, value: v.sqlValue)
    }
    mutating func encode(_ v: Int8, forKey key: Key) throws {
        storage.append(key: key.stringValue, value: Int64(v).sqlValue)
    }
    mutating func encode(_ v: Int16, forKey key: Key) throws {
        storage.append(key: key.stringValue, value: Int64(v).sqlValue)
    }
    mutating func encode(_ v: Int32, forKey key: Key) throws {
        storage.append(key: key.stringValue, value: v.sqlValue)
    }
    mutating func encode(_ v: Int64, forKey key: Key) throws {
        storage.append(key: key.stringValue, value: v.sqlValue)
    }
    mutating func encode(_ v: UInt, forKey key: Key) throws {
        storage.append(key: key.stringValue, value: Int64(bitPattern: UInt64(v)).sqlValue)
    }
    mutating func encode(_ v: UInt8, forKey key: Key) throws {
        storage.append(key: key.stringValue, value: Int64(v).sqlValue)
    }
    mutating func encode(_ v: UInt16, forKey key: Key) throws {
        storage.append(key: key.stringValue, value: Int64(v).sqlValue)
    }
    mutating func encode(_ v: UInt32, forKey key: Key) throws {
        storage.append(key: key.stringValue, value: Int64(v).sqlValue)
    }
    mutating func encode(_ v: UInt64, forKey key: Key) throws {
        storage.append(key: key.stringValue, value: Int64(bitPattern: v).sqlValue)
    }

    // MARK: Generic Encodable

    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        // Date
        if let date = value as? Date {
            storage.append(key: key.stringValue, value: encodeDate(date, strategy: dateStrategy))
            return
        }
        // UUID → text
        if let uuid = value as? UUID {
            storage.append(key: key.stringValue, value: .text(uuid.uuidString))
            return
        }
        // Data → blob (must come before generic Encodable to prevent byte-array recursion)
        if let data = value as? Data {
            storage.append(key: key.stringValue, value: .blob(data))
            return
        }
        // Any SQLConvertible (catches Int?, String?, custom types, etc.)
        if let sqlVal = value as? any SQLConvertible {
            storage.append(key: key.stringValue, value: sqlVal.sqlValue)
            return
        }
        // Fallback: try to capture as a single scalar (handles enum raw values etc.)
        let capture = _SingleValueCaptureEncoder(
            codingPath: codingPath + [key], dateStrategy: dateStrategy)
        var captureThrew: (any Error)?
        do { try value.encode(to: capture) } catch { captureThrew = error }
        if let captured = capture.captured {
            storage.append(key: key.stringValue, value: captured)
            return
        }
        // Complex type (array, dict, nested struct): apply the column strategy.
        if let strategy = complexStrategy {
            storage.append(key: key.stringValue, value: try strategy.encode(value))
            return
        }
        if let err = captureThrew { throw err }
        throw EncodingError.invalidValue(
            value,
            .init(
                codingPath: codingPath + [key],
                debugDescription:
                    "RowEncoder cannot encode \(T.self) as a scalar SQL value. "
                    + "Set complexColumnStrategy on the Database to handle complex types."))
    }

    // MARK: Nested / super

    mutating func nestedContainer<NK: CodingKey>(
        keyedBy type: NK.Type, forKey key: Key
    ) -> KeyedEncodingContainer<NK> {
        KeyedEncodingContainer(
            _KeyedContainer<NK>(
                storage: storage, codingPath: codingPath + [key], dateStrategy: dateStrategy,
                complexStrategy: complexStrategy))
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        _ThrowingUnkeyedContainer(codingPath: codingPath + [key])
    }

    mutating func superEncoder() -> Encoder {
        _RowEncoder(
            storage: storage, codingPath: codingPath, dateStrategy: dateStrategy,
            complexStrategy: complexStrategy)
    }

    mutating func superEncoder(forKey key: Key) -> Encoder {
        _RowEncoder(
            storage: storage, codingPath: codingPath + [key], dateStrategy: dateStrategy,
            complexStrategy: complexStrategy)
    }
}

// MARK: - _SingleValueContainer

/// A single-value container that appends to the shared storage using a pre-
/// determined key. Used when `singleValueContainer()` is called from within an
/// Optional's `encode(to:)` — the key comes from the parent context via
/// `codingPath`.
private struct _SingleValueContainer: SingleValueEncodingContainer {
    let storage: _EncoderStorage
    let codingPath: [CodingKey]
    let dateStrategy: RowEncoder.DateEncodingStrategy
    let complexStrategy: ComplexColumnStrategy?

    private var key: String { codingPath.last?.stringValue ?? "" }

    mutating func encodeNil() throws { storage.append(key: key, value: .null) }
    mutating func encode(_ v: Bool) throws { storage.append(key: key, value: v.sqlValue) }
    mutating func encode(_ v: String) throws { storage.append(key: key, value: v.sqlValue) }
    mutating func encode(_ v: Double) throws { storage.append(key: key, value: v.sqlValue) }
    mutating func encode(_ v: Float) throws { storage.append(key: key, value: Float(v).sqlValue) }
    mutating func encode(_ v: Int) throws { storage.append(key: key, value: v.sqlValue) }
    mutating func encode(_ v: Int8) throws { storage.append(key: key, value: Int64(v).sqlValue) }
    mutating func encode(_ v: Int16) throws { storage.append(key: key, value: Int64(v).sqlValue) }
    mutating func encode(_ v: Int32) throws { storage.append(key: key, value: v.sqlValue) }
    mutating func encode(_ v: Int64) throws { storage.append(key: key, value: v.sqlValue) }
    mutating func encode(_ v: UInt) throws {
        storage.append(key: key, value: Int64(bitPattern: UInt64(v)).sqlValue)
    }
    mutating func encode(_ v: UInt8) throws { storage.append(key: key, value: Int64(v).sqlValue) }
    mutating func encode(_ v: UInt16) throws { storage.append(key: key, value: Int64(v).sqlValue) }
    mutating func encode(_ v: UInt32) throws { storage.append(key: key, value: Int64(v).sqlValue) }
    mutating func encode(_ v: UInt64) throws {
        storage.append(key: key, value: Int64(bitPattern: v).sqlValue)
    }

    mutating func encode<T: Encodable>(_ value: T) throws {
        if let date = value as? Date {
            storage.append(key: key, value: encodeDate(date, strategy: dateStrategy))
            return
        }
        if let uuid = value as? UUID {
            storage.append(key: key, value: .text(uuid.uuidString))
            return
        }
        if let data = value as? Data {
            storage.append(key: key, value: .blob(data))
            return
        }
        if let sql = value as? any SQLConvertible {
            storage.append(key: key, value: sql.sqlValue)
            return
        }
        // Fallback: try to capture as a single scalar (handles enum raw values etc.)
        let capture = _SingleValueCaptureEncoder(codingPath: codingPath, dateStrategy: dateStrategy)
        var captureThrew: (any Error)?
        do { try value.encode(to: capture) } catch { captureThrew = error }
        if let captured = capture.captured {
            storage.append(key: key, value: captured)
            return
        }
        // Complex type: apply the column strategy.
        if let strategy = complexStrategy {
            storage.append(key: key, value: try strategy.encode(value))
            return
        }
        if let err = captureThrew { throw err }
        throw EncodingError.invalidValue(
            value,
            .init(
                codingPath: codingPath,
                debugDescription:
                    "RowEncoder cannot encode \(T.self) as a scalar SQL value. "
                    + "Set complexColumnStrategy on the Database to handle complex types."))
    }
}

// MARK: - _SingleValueCaptureEncoder
//
// An Encoder that reduces a nested Encodable to a single Value, used for
// enum raw-value types and similar single-column representations.

private final class _SingleValueCaptureEncoder: Encoder {
    let codingPath: [CodingKey]
    let userInfo: [CodingUserInfoKey: Any] = [:]
    let dateStrategy: RowEncoder.DateEncodingStrategy
    var captured: Value?

    init(codingPath: [CodingKey], dateStrategy: RowEncoder.DateEncodingStrategy) {
        self.codingPath = codingPath
        self.dateStrategy = dateStrategy
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        // Should not be reached for raw-value enums; provide a no-op container.
        KeyedEncodingContainer(_NullKeyedContainer<Key>(codingPath: codingPath))
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        _ThrowingUnkeyedContainer(codingPath: codingPath)
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        _CaptureContainer(encoder: self)
    }
}

private struct _CaptureContainer: SingleValueEncodingContainer {
    let encoder: _SingleValueCaptureEncoder
    var codingPath: [CodingKey] { encoder.codingPath }

    mutating func encodeNil() throws { encoder.captured = .null }
    mutating func encode(_ v: Bool) throws { encoder.captured = v.sqlValue }
    mutating func encode(_ v: String) throws { encoder.captured = v.sqlValue }
    mutating func encode(_ v: Double) throws { encoder.captured = v.sqlValue }
    mutating func encode(_ v: Float) throws { encoder.captured = Float(v).sqlValue }
    mutating func encode(_ v: Int) throws { encoder.captured = v.sqlValue }
    mutating func encode(_ v: Int8) throws { encoder.captured = Int64(v).sqlValue }
    mutating func encode(_ v: Int16) throws { encoder.captured = Int64(v).sqlValue }
    mutating func encode(_ v: Int32) throws { encoder.captured = v.sqlValue }
    mutating func encode(_ v: Int64) throws { encoder.captured = v.sqlValue }
    mutating func encode(_ v: UInt) throws {
        encoder.captured = Int64(bitPattern: UInt64(v)).sqlValue
    }
    mutating func encode(_ v: UInt8) throws { encoder.captured = Int64(v).sqlValue }
    mutating func encode(_ v: UInt16) throws { encoder.captured = Int64(v).sqlValue }
    mutating func encode(_ v: UInt32) throws { encoder.captured = Int64(v).sqlValue }
    mutating func encode(_ v: UInt64) throws { encoder.captured = Int64(bitPattern: v).sqlValue }

    mutating func encode<T: Encodable>(_ value: T) throws {
        if let date = value as? Date {
            encoder.captured = encodeDate(date, strategy: encoder.dateStrategy)
            return
        }
        if let uuid = value as? UUID {
            encoder.captured = .text(uuid.uuidString)
            return
        }
        if let data = value as? Data {
            encoder.captured = .blob(data)
            return
        }
        if let sql = value as? any SQLConvertible {
            encoder.captured = sql.sqlValue
            return
        }
        try value.encode(to: encoder)
    }
}

// MARK: - No-op / throwing stubs

private struct _ThrowingUnkeyedContainer: UnkeyedEncodingContainer {
    let codingPath: [CodingKey]
    var count: Int = 0

    mutating func encodeNil() throws { throw _unsupported(codingPath) }
    mutating func encode(_ v: Bool) throws { throw _unsupported(codingPath) }
    mutating func encode(_ v: String) throws { throw _unsupported(codingPath) }
    mutating func encode(_ v: Double) throws { throw _unsupported(codingPath) }
    mutating func encode(_ v: Float) throws { throw _unsupported(codingPath) }
    mutating func encode(_ v: Int) throws { throw _unsupported(codingPath) }
    mutating func encode(_ v: Int8) throws { throw _unsupported(codingPath) }
    mutating func encode(_ v: Int16) throws { throw _unsupported(codingPath) }
    mutating func encode(_ v: Int32) throws { throw _unsupported(codingPath) }
    mutating func encode(_ v: Int64) throws { throw _unsupported(codingPath) }
    mutating func encode(_ v: UInt) throws { throw _unsupported(codingPath) }
    mutating func encode(_ v: UInt8) throws { throw _unsupported(codingPath) }
    mutating func encode(_ v: UInt16) throws { throw _unsupported(codingPath) }
    mutating func encode(_ v: UInt32) throws { throw _unsupported(codingPath) }
    mutating func encode(_ v: UInt64) throws { throw _unsupported(codingPath) }
    mutating func encode<T: Encodable>(_ v: T) throws { throw _unsupported(codingPath) }
    mutating func nestedContainer<K: CodingKey>(keyedBy: K.Type) -> KeyedEncodingContainer<K> {
        KeyedEncodingContainer(_NullKeyedContainer<K>(codingPath: codingPath))
    }
    mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer { self }
    mutating func superEncoder() -> Encoder {
        _SingleValueCaptureEncoder(codingPath: codingPath, dateStrategy: .deferredToDate)
    }
}

private struct _NullKeyedContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let codingPath: [CodingKey]
    mutating func encodeNil(forKey key: Key) throws {}
    mutating func encode(_ v: Bool, forKey key: Key) throws {}
    mutating func encode(_ v: String, forKey key: Key) throws {}
    mutating func encode(_ v: Double, forKey key: Key) throws {}
    mutating func encode(_ v: Float, forKey key: Key) throws {}
    mutating func encode(_ v: Int, forKey key: Key) throws {}
    mutating func encode(_ v: Int8, forKey key: Key) throws {}
    mutating func encode(_ v: Int16, forKey key: Key) throws {}
    mutating func encode(_ v: Int32, forKey key: Key) throws {}
    mutating func encode(_ v: Int64, forKey key: Key) throws {}
    mutating func encode(_ v: UInt, forKey key: Key) throws {}
    mutating func encode(_ v: UInt8, forKey key: Key) throws {}
    mutating func encode(_ v: UInt16, forKey key: Key) throws {}
    mutating func encode(_ v: UInt32, forKey key: Key) throws {}
    mutating func encode(_ v: UInt64, forKey key: Key) throws {}
    mutating func encode<T: Encodable>(_ v: T, forKey key: Key) throws {}
    mutating func nestedContainer<NK: CodingKey>(keyedBy type: NK.Type, forKey key: Key)
        -> KeyedEncodingContainer<NK> { KeyedEncodingContainer(_NullKeyedContainer<NK>(codingPath: codingPath + [key])) }
    mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        _ThrowingUnkeyedContainer(codingPath: codingPath + [key])
    }
    mutating func superEncoder() -> Encoder {
        _SingleValueCaptureEncoder(codingPath: codingPath, dateStrategy: .deferredToDate)
    }
    mutating func superEncoder(forKey key: Key) -> Encoder {
        _SingleValueCaptureEncoder(codingPath: codingPath + [key], dateStrategy: .deferredToDate)
    }
}

// MARK: - Date helper

private func encodeDate(_ date: Date, strategy: RowEncoder.DateEncodingStrategy) -> Value {
    switch strategy {
    case .deferredToDate:
        return .real(date.timeIntervalSinceReferenceDate)
    case .secondsSince1970:
        return .real(date.timeIntervalSince1970)
    case .millisecondsSince1970:
        return .real(date.timeIntervalSince1970 * 1000)
    case .iso8601:
        if #available(macOS 10.12, iOS 10.0, tvOS 10.0, watchOS 3.0, *) {
            return .text(ISO8601DateFormatter().string(from: date))
        }
        return .real(date.timeIntervalSince1970)
    case .formatted(let fmt):
        return .text(fmt.string(from: date))
    case .custom(let fn):
        return fn(date)
    }
}

private func _unsupported(_ codingPath: [CodingKey]) -> EncodingError {
    EncodingError.invalidValue(
        "unkeyed container",
        .init(
            codingPath: codingPath,
            debugDescription: "RowEncoder does not support unkeyed (array) containers. "
                + "Encode structs with named properties instead."))
}
