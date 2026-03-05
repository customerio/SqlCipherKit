/// Errors thrown by SqlCipherKit operations.
public enum SqlCipherError: Error, Sendable {

    // MARK: - Lifecycle
    /// Failed to open or create the database file.
    case openFailed(message: String)
    /// The encryption key could not be applied (e.g. wrong key for an existing database).
    case keyFailed(code: Int32)

    // MARK: - Statement
    /// SQL could not be compiled into a prepared statement.
    case prepareFailed(sql: String, message: String)
    /// A step (row fetch) returned an unexpected error.
    case stepFailed(message: String)
    /// A value could not be bound to a statement parameter.
    case bindFailed(index: Int32, code: Int32)

    // MARK: - Result reading
    /// A column name referenced in a `Row` subscript does not exist.
    case columnNotFound(name: String)
    /// A value in the result set cannot be converted to the requested Swift type.
    case typeMismatch(column: String, expected: String, got: String)
}
