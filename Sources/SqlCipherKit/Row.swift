import Foundation

/// An immutable snapshot of a single result row returned by a SQL query.
///
/// Columns are accessible by zero-based index or by name:
/// ```swift
/// let id:   Int64  = row.get(0, as: Int64.self) ?? 0
/// let name: String = row.get("name", as: String.self) ?? ""
/// ```
public struct Row: Sendable {

    // MARK: - Storage

    /// Maps column name → positional index.
    private let columnIndex: [String: Int]
    /// Ordered column values.
    private let values: [Value]

    // MARK: - Internal init

    init(columnIndex: [String: Int], values: [Value]) {
        self.columnIndex = columnIndex
        self.values = values
    }

    // MARK: - Public interface

    /// The number of columns in this row.
    public var count: Int { values.count }

    /// Returns the raw `Value` at a zero-based column index.
    ///
    /// - Precondition: `index` must be within `0..<count`.
    public subscript(index: Int) -> Value {
        values[index]
    }

    /// Returns the raw `Value` for the named column, or `nil` if the column
    /// does not exist.
    public subscript(name: String) -> Value? {
        guard let idx = columnIndex[name] else { return nil }
        return values[idx]
    }

    // MARK: - Typed access by index

    /// Converts the value at `index` to `T`, returning `nil` when the column
    /// holds `NULL` or the conversion is not possible.
    public func get<T: SQLConvertible>(_ index: Int, as type: T.Type = T.self) -> T? {
        T.from(sqlValue: values[index])
    }

    // MARK: - Typed access by name

    /// Converts the named column to `T`, returning `nil` when the column is
    /// not present, holds `NULL`, or the conversion is not possible.
    public func get<T: SQLConvertible>(_ name: String, as type: T.Type = T.self) -> T? {
        guard let idx = columnIndex[name] else { return nil }
        return T.from(sqlValue: values[idx])
    }

    /// Converts the named column to `T`, throwing when the column is not found
    /// or the type conversion fails.
    public func require<T: SQLConvertible>(
        _ name: String,
        as type: T.Type = T.self
    ) throws -> T {
        guard let idx = columnIndex[name] else {
            throw SqlCipherError.columnNotFound(name: name)
        }
        guard let value = T.from(sqlValue: values[idx]) else {
            throw SqlCipherError.typeMismatch(
                column: name,
                expected: String(describing: T.self),
                got: String(describing: values[idx])
            )
        }
        return value
    }
}

// MARK: - CustomStringConvertible

extension Row: CustomStringConvertible {
    public var description: String {
        let pairs = columnIndex
            .sorted { $0.value < $1.value }
            .map { "\($0.key): \(values[$0.value])" }
        return "Row(\(pairs.joined(separator: ", ")))"
    }
}
