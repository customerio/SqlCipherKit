import Foundation

// MARK: - ComplexColumnStrategy

/// Determines how properties that cannot be mapped to a scalar SQL ``Value``
/// — arrays, dictionaries, and nested `Codable` structs — are encoded into
/// and decoded from a single TEXT or BLOB column.
///
/// The default strategy is ``json``, which stores the value as a UTF-8 JSON
/// string in a `TEXT` column, and decodes it back with `JSONDecoder`.
///
/// Configure the strategy once on the `Database` instance:
///
/// ```swift
/// let db = try Database(path: path, key: key)
///
/// // Default — no change needed:
/// db.complexColumnStrategy = .json
///
/// // Custom JSONEncoder/JSONDecoder (e.g. sorted keys, snake_case dates):
/// let enc = JSONEncoder(); enc.keyEncodingStrategy = .convertToSnakeCase
/// let dec = JSONDecoder(); dec.keyDecodingStrategy = .convertFromSnakeCase
/// db.complexColumnStrategy = .json(encoder: enc, decoder: dec)
///
/// // Fail loudly when a complex property is encountered (good for catching
/// // schema bugs early in development):
/// db.complexColumnStrategy = nil
/// ```
///
/// ### Column DDL
///
/// JSON-encoded columns should be declared `TEXT NOT NULL` (or `TEXT` for
/// optional properties) in your schema:
///
/// ```swift
/// CreateTable(table)
///     .column("tags",     .text, .notNull)   // stores ["a","b"] as JSON
///     .column("metadata", .text)             // stores {"k":"v"} as JSON or NULL
/// ```
public struct ComplexColumnStrategy: Sendable {

    // MARK: - Internal encode/decode closures

    let _encode: @Sendable (any Encodable) throws -> Value
    let _decode: @Sendable (any Decodable.Type, Value) throws -> any Decodable

    // MARK: - Built-in strategies

    /// Encodes complex values as JSON text and decodes with `JSONDecoder`.
    ///
    /// This is the default strategy on every `Database` instance.
    public static let json: ComplexColumnStrategy = .json()

    /// Creates a JSON strategy with custom `JSONEncoder` and `JSONDecoder`
    /// instances, giving control over key encoding strategy, date format, etc.
    ///
    /// - Parameters:
    ///   - encoder: The `JSONEncoder` to use for encoding.  Defaults to a
    ///     fresh instance with no custom settings.
    ///   - decoder: The `JSONDecoder` to use for decoding.  Defaults to a
    ///     fresh instance with no custom settings.
    public static func json(
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) -> ComplexColumnStrategy {
        ComplexColumnStrategy(
            _encode: { value in
                let data = try _jsonEncode(value, using: encoder)
                guard let text = String(data: data, encoding: .utf8) else {
                    throw EncodingError.invalidValue(
                        value,
                        EncodingError.Context(
                            codingPath: [],
                            debugDescription: "JSON output could not be converted to UTF-8."))
                }
                return .text(text)
            },
            _decode: { type, sqlValue in
                guard case .text(let s) = sqlValue, let data = s.data(using: .utf8) else {
                    throw DecodingError.dataCorrupted(
                        .init(
                            codingPath: [],
                            debugDescription:
                                "ComplexColumnStrategy.json expected a TEXT column, got \(sqlValue)."
                        ))
                }
                return try decoder.decode(type, from: data)
            }
        )
    }

    /// Creates a fully custom strategy with caller-supplied encode and decode
    /// closures.
    ///
    /// - Parameters:
    ///   - encode: Closure that converts any `Encodable` value to a SQL
    ///     ``Value``.  Typically `.text(…)` or `.blob(…)`.
    ///   - decode: Closure that converts a SQL ``Value`` back to a `Decodable`
    ///     value of the given metatype.
    public static func custom(
        encode: @Sendable @escaping (any Encodable) throws -> Value,
        decode: @Sendable @escaping (any Decodable.Type, Value) throws -> any Decodable
    ) -> ComplexColumnStrategy {
        ComplexColumnStrategy(_encode: encode, _decode: decode)
    }

    // MARK: - Helpers called by RowEncoder / RowDecoder

    func encode(_ value: any Encodable) throws -> Value {
        try _encode(value)
    }

    func decode<T: Decodable>(_ type: T.Type, from sqlValue: Value) throws -> T {
        let result = try _decode(type, sqlValue)
        guard let typed = result as? T else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: [],
                    debugDescription:
                        "ComplexColumnStrategy.decode returned an unexpected type for \(T.self)."))
        }
        return typed
    }
}

// MARK: - Type-erasure helpers (file-private)

/// Wraps `any Encodable` in a concrete box so `JSONEncoder.encode(_:)`,
/// which requires a concrete `T: Encodable`, can accept an existential.
private struct _EncodableBox: Encodable {
    let base: any Encodable
    func encode(to encoder: any Encoder) throws { try base.encode(to: encoder) }
}

private func _jsonEncode(_ value: any Encodable, using encoder: JSONEncoder) throws -> Data {
    try encoder.encode(_EncodableBox(base: value))
}
