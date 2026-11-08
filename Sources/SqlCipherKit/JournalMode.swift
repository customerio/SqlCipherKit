// MARK: - JournalMode

/// How SQLite records changes so that a transaction can be rolled back.
///
/// The journal mode is chosen when a database is created, stored in the
/// file, and read back on every later open.  SqlCipherKit never changes the
/// journal mode of an existing database; ``Database/journalMode`` reports
/// the mode the file is actually in.
///
/// In-memory databases (path `":memory:"`) always keep their rollback journal
/// in memory and report ``rollback`` whatever mode is requested.
public enum JournalMode: Sendable, Hashable, CaseIterable {

    /// Write-ahead logging (`PRAGMA journal_mode = WAL`).  The default.
    ///
    /// Cheaper commits than the rollback journal, at the cost of `-wal` and
    /// `-shm` sidecar files that exist until the last connection closes.
    case wal

    /// The rollback journal (`PRAGMA journal_mode = DELETE`).
    ///
    /// Keeps the database a single file whenever no transaction is in
    /// progress.  Choose this for files that are copied between media,
    /// backed up as opaque blobs, or read from read-only storage.
    case rollback

    /// The value passed to `PRAGMA journal_mode = …`.
    var pragmaValue: String {
        switch self {
        case .wal: return "WAL"
        case .rollback: return "DELETE"
        }
    }

    /// The lowercase name SQLite reports from `PRAGMA journal_mode`.
    var sqliteName: String {
        switch self {
        case .wal: return "wal"
        case .rollback: return "delete"
        }
    }

    init?(sqliteName: String) {
        switch sqliteName.lowercased() {
        case "wal": self = .wal
        case "delete": self = .rollback
        default: return nil
        }
    }
}
