/// Errors thrown by SqlCipherKit operations.
public enum SqlCipherError: Error, Sendable {

    // MARK: - Lifecycle
    /// Failed to open or create the database file.
    case openFailed(message: String)
    /// The encryption key could not be applied (e.g. wrong key for an existing
    /// database, a passphrase used on a raw-key database or the reverse, or a
    /// key used on an unencrypted database).
    case keyFailed(code: Int32)
    /// The supplied key is unusable: an empty passphrase, or a raw key that is
    /// not ``Database/rawKeyLength`` bytes.  Thrown before the file is touched.
    case invalidKey(reason: String)
    /// A file opened with ``Database/init(unencryptedPath:journalMode:complexColumnStrategy:)``
    /// is encrypted or is not a SQLite database.
    case notPlaintextDatabase(code: Int32)
    /// ``Database/rekey(_:)`` or ``Database/rekey(rawKey:)`` was called on an
    /// unencrypted database.
    case notEncrypted
    /// SQLite did not accept the journal mode requested for a new database.
    case journalModeFailed(requested: JournalMode, actual: String)
    /// An existing database is in a journal mode other than WAL or rollback
    /// (`DELETE`), so it was not created by SqlCipherKit.
    case unsupportedJournalMode(String)

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
