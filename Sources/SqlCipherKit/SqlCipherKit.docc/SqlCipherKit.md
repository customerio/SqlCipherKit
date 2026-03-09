# ``SqlCipherKit``

An actor-isolated, encrypted SQLite database for Swift.

## Overview

SqlCipherKit wraps [SQLCipher](https://www.zetetic.net/sqlcipher/) — an AES-256-encrypted fork of SQLite — in a modern Swift API designed for safe concurrent use.

Key capabilities:

- **Encrypted by default.** Every database file is encrypted at rest with a key you supply at open-time.
- **Actor isolation.** The ``Database`` actor serialises all access, making it safe to call from any `async` context without additional locking.
- **`Entity` persistence.** Conform your `Codable` models to ``Entity`` and get automatic INSERT, UPDATE, DELETE, and SELECT helpers with zero boilerplate.
- **Composable query builders.** Construct type-safe `SELECT`, `UPDATE`, `INSERT`, `CREATE TABLE`, and schema-alteration statements programmatically.
- **Migrations.** Drive schema evolution with the ``Migration`` protocol and ``MigrationContext``.
- **No external dependencies on Apple platforms.** Uses CommonCrypto (bundled with the OS) as the SQLCipher crypto backend.

## Topics

### Getting Started

- ``Database``
- ``Entity``
- ``Migration``

### Querying

- ``Row``
- ``Value``
- ``SQLConvertible``

### Query Builders

- ``SelectBuilder``
- ``UpdateBuilder``
- ``InsertBuilder``

### Schema Builders

- ``CreateTableBuilder``
- ``AlterTableBuilder``
- ``DropTableBuilder``
- ``CreateIndexBuilder``
- ``DropIndexBuilder``

### Configuration

- ``ComplexColumnStrategy``

### Errors

- ``SqlCipherError``
