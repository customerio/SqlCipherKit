import Foundation

// MARK: - Value

/// A typed representation of a single SQLite column value.
public enum Value: Sendable, Hashable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

// MARK: - CustomStringConvertible

extension Value: CustomStringConvertible {
    public var description: String {
        switch self {
        case .null: return "NULL"
        case .integer(let i): return "\(i)"
        case .real(let d): return "\(d)"
        case .text(let s): return s
        case .blob(let d): return "<\(d.count) bytes>"
        }
    }
}

// MARK: - SQLConvertible

/// A type that can be round-tripped through an SQLite column value.
///
/// Conform your own types to both encode them as SQL parameters and decode them
/// from result rows.  For example:
/// ```swift
/// extension MyID: SQLConvertible {
///     var sqlValue: Value { .integer(Int64(rawValue)) }
///     static func from(sqlValue: Value) -> Self? {
///         guard case .integer(let i) = sqlValue else { return nil }
///         return Self(rawValue: Int(i))
///     }
/// }
/// ```
public protocol SQLConvertible: Sendable {
    /// Encode this value as an SQLite `Value`.
    var sqlValue: Value { get }
    /// Decode a `Value` into `Self`, returning `nil` when the conversion is
    /// not possible (e.g. wrong variant or incompatible range).
    static func from(sqlValue: Value) -> Self?
}

// MARK: Value itself is SQLConvertible

extension Value: SQLConvertible {
    public var sqlValue: Value { self }
    public static func from(sqlValue: Value) -> Value? { sqlValue }
}

// MARK: - Standard library conformances

extension String: SQLConvertible {
    public var sqlValue: Value { .text(self) }
    public static func from(sqlValue: Value) -> String? {
        if case .text(let s) = sqlValue { return s }
        return nil
    }
}

extension Int: SQLConvertible {
    public var sqlValue: Value { .integer(Int64(self)) }
    public static func from(sqlValue: Value) -> Int? {
        if case .integer(let i) = sqlValue { return Int(exactly: i) }
        return nil
    }
}

extension Int32: SQLConvertible {
    public var sqlValue: Value { .integer(Int64(self)) }
    public static func from(sqlValue: Value) -> Int32? {
        if case .integer(let i) = sqlValue { return Int32(exactly: i) }
        return nil
    }
}

extension Int64: SQLConvertible {
    public var sqlValue: Value { .integer(self) }
    public static func from(sqlValue: Value) -> Int64? {
        if case .integer(let i) = sqlValue { return i }
        return nil
    }
}

extension Double: SQLConvertible {
    public var sqlValue: Value { .real(self) }
    public static func from(sqlValue: Value) -> Double? {
        switch sqlValue {
        case .real(let d): return d
        case .integer(let i): return Double(i)
        default: return nil
        }
    }
}

extension Float: SQLConvertible {
    public var sqlValue: Value { .real(Double(self)) }
    public static func from(sqlValue: Value) -> Float? {
        switch sqlValue {
        case .real(let d): return Float(d)
        case .integer(let i): return Float(i)
        default: return nil
        }
    }
}

extension Bool: SQLConvertible {
    public var sqlValue: Value { .integer(self ? 1 : 0) }
    public static func from(sqlValue: Value) -> Bool? {
        if case .integer(let i) = sqlValue { return i != 0 }
        return nil
    }
}

extension Data: SQLConvertible {
    public var sqlValue: Value { .blob(self) }
    public static func from(sqlValue: Value) -> Data? {
        if case .blob(let d) = sqlValue { return d }
        return nil
    }
}

// MARK: - Optional conformance

/// Allows `Optional<T>` to round-trip through SQL columns.
///
/// - `nil` encodes as `.null`.
/// - `.null` decodes back to `nil` (i.e. `.some(.none)`, not `.none`).
///   A `.none` return from `from(sqlValue:)` indicates a parsing failure,
///   not a SQL NULL — that distinction matters for generic code that checks
///   whether decoding succeeded.
extension Optional: SQLConvertible where Wrapped: SQLConvertible {
    public var sqlValue: Value { self?.sqlValue ?? .null }

    /// Returns `.some(.none)` for SQL NULL, `.some(.some(value))` on success,
    /// or `.none` when the value is present but cannot be parsed as `Wrapped`.
    public static func from(sqlValue: Value) -> Self? {
        if case .null = sqlValue { return .some(.none) }
        return Wrapped.from(sqlValue: sqlValue).map { .some($0) }
    }
}
