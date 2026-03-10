# Changelog

All notable changes to SqlCipherKit will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
