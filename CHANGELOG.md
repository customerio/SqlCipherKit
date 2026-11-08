# Changelog

All notable changes to SqlCipherKit will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Raw key mode: `Database(path:rawKey:)` and `rekey(rawKey:)` take a 32-byte key and apply it as SQLCipher's `x'…'` literal, skipping PBKDF2. Either kind of key can replace either kind on rekey.
- Unencrypted databases: `Database(unencryptedPath:)` manages a plain SQLite file through the same API. `isEncrypted` reports which kind a `Database` holds; `rekey` throws `SqlCipherError.notEncrypted` on an unencrypted database.
- `JournalMode` (`.wal`, the default, or `.rollback`), chosen when a database is created. `journalMode` reports the mode the file is in.
- `Database.transaction(_:)`: runs a body in `BEGIN` … `COMMIT`, rolling back on a thrown error.
- Entity operations on `Connection` (`save`, `fetch`, `fetchOne`, `delete`), so entities can be used inside `transaction(_:)` and `withConnection(_:)`.
- `Connection.savepoint(_:)` for nested, independently undoable steps.
- Entity delete: `delete(_:id:)` and `delete(_:where:_:)`, returning the number of rows deleted.
- `SqlCipherError` cases `invalidKey`, `notPlaintextDatabase`, `notEncrypted`, `journalModeFailed`, and `unsupportedJournalMode`.

### Changed
- An empty passphrase now throws `SqlCipherError.invalidKey` before the file is touched. Previously SQLCipher silently created an unencrypted database.
- The journal mode is applied only when a database is created. Opening an existing database no longer switches it to WAL. An existing file in a mode other than WAL or rollback (`DELETE`) throws `SqlCipherError.unsupportedJournalMode`. In-memory databases are unaffected and report `.rollback`.
- Batch `save([...])` uses a `SAVEPOINT` instead of `BEGIN` / `COMMIT`, so it nests inside a transaction.
- Code that switches exhaustively over `SqlCipherError` must handle the new cases.

### Deprecated
- `Database(path:key:walMode:complexColumnStrategy:)`. Use `journalMode:`; `walMode: false` maps to `.rollback`.

## [0.9.0] - 2026-03-10

### Added
- Initial release of SqlCipherKit.
- Actor-isolated `Database` type for safe concurrent access.
- `Entity` protocol for `Codable`-backed table mapping with automatic INSERT, UPDATE, DELETE, and SELECT helpers.
- Composable query builders: `Select`, `Update`, `Insert`, `CreateTable`, `AlterTable`, `DropTable`, `CreateIndex`, `DropIndex`.
- `Migration` protocol with `MigrationContext` for forward and rollback schema migrations.
- `ComplexColumnStrategy` for encoding non-scalar `Codable` properties as JSON.
- `Row` and `Value` types for typed result-set access.
- `SQLConvertible` protocol for custom type round-tripping through SQLite column values.
- Statement cache for prepared statement reuse.
- CommonCrypto backend on macOS, iOS, and visionOS (no additional dependencies).
- OpenSSL/libcrypto backend on Linux.
