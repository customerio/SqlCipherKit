# SqlCipherKit

SqlCipherKit is a Swift wrapper around [SQLCipher](https://www.zetetic.net/sqlcipher/), providing an actor-isolated, encrypted SQLite database with lightweight ORM-like persistence and a composable query-builder API. It does not aim to be a full-featured ORM; instead it offers a thin, type-safe layer for common patterns — raw SQL execution, fluent SELECT/UPDATE/INSERT builders, and a `Codable`-backed `Entity` protocol for straightforward table mapping.

On Apple platforms (**macOS 10.15+, iOS 13+, visionOS 1+**) the library uses Apple's **CommonCrypto** framework as the cryptographic backend for SQLCipher, which requires no additional dependencies. On **Linux**, the OpenSSL crypto backend is used instead, which requires `libcrypto` to be available on the build machine (typically provided by `libssl-dev` on Debian/Ubuntu or `openssl-devel` on Fedora/RHEL).

---

## Requirements

| Platform | Minimum Version | Crypto backend | System prerequisite |
|---|---|---|---|
| macOS | 10.15 | CommonCrypto | None |
| iOS | 13 | CommonCrypto | None |
| visionOS | 1 | CommonCrypto | None |
| Linux | — | OpenSSL | `libssl-dev` / `openssl-devel` |

---

## Installation

### Swift Package Manager

Add the dependency to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/customerio/SqlCipherKit.git", from: "1.0.0"),
],
targets: [
    .target(
        name: "MyTarget",
        dependencies: ["SqlCipherKit"]
    ),
]
```

### Xcode Project

1. In Xcode, open **File → Add Package Dependencies…**
2. Enter `https://github.com/customerio/SqlCipherKit` and select the version rule you want.
3. Add **SqlCipherKit** to the desired target.

---

## Usage

Open or create an encrypted database by providing a filesystem path and a passphrase. The passphrase is run through PBKDF2-HMAC-SHA512 by SQLCipher before use.

```swift
import SqlCipherKit

let db = try Database(path: "/path/to/store.db", key: "my-passphrase")
```

`Database` is a Swift actor, so all of its methods are called with `try await` when invoked from an async context.

An empty passphrase is rejected: SQLCipher treats an empty key as "no encryption", so plaintext is never produced by accident. Use the unencrypted initialiser below when plaintext is what you want.

### Raw keys

When you already hold a full-entropy 32-byte key (for example the output of a KDF you run yourself, or a key stored in the Keychain), pass it as `Data`. SQLCipher uses it directly and skips its own PBKDF2 stretching, so opening costs no key derivation. A database created with a raw key cannot be opened with a passphrase, or the reverse.

```swift
let key: Data = ...  // exactly 32 bytes
let db = try Database(path: "/path/to/store.db", rawKey: key)
try await db.rekey(rawKey: newKey)   // or db.rekey("a passphrase")
```

### Unencrypted databases

For data that is public or already ciphertext, `Database` can manage a plain SQLite file with the same API. No key is applied, the file is readable by any SQLite tool, `isEncrypted` is `false`, and `rekey` throws.

```swift
let db = try Database(unencryptedPath: "/path/to/public.db")
```

Opening an encrypted file this way throws `SqlCipherError.notPlaintextDatabase`; opening an unencrypted file with a key throws `SqlCipherError.keyFailed`.

### Journal mode

New databases use WAL by default. Pass `.rollback` for files that must stay a single file whenever no transaction is running, such as files copied between media, backed up as opaque blobs, or opened from read-only storage. The mode is fixed when the database is created: opening an existing file keeps its mode, whatever you pass, and `db.journalMode` reports the mode the file is in.

```swift
let db = try Database(path: "/path/to/store.db", key: "my-passphrase", journalMode: .rollback)
let pub = try Database(unencryptedPath: "/path/to/public.db", journalMode: .rollback)
```

### Raw SQL

For straightforward one-shot statements, pass SQL directly with `?` positional placeholders:

```swift
// DDL
try await db.execute("""
    CREATE TABLE IF NOT EXISTS products (
        id    INTEGER PRIMARY KEY,
        name  TEXT    NOT NULL,
        price REAL    NOT NULL
    )
""")

// Query
let rows = try await db.query(
    "SELECT id, name, price FROM products WHERE price < ? ORDER BY price",
    50.0
)
for row in rows {
    let name  = row.get("name",  as: String.self)
    let price = row.get("price", as: Double.self)
    print("\(name ?? "-"): \(price ?? 0)")
}

// Update
try await db.execute(
    "UPDATE products SET price = ? WHERE id = ?",
    39.99, 7
)
```

### Query Builder

The query builder separates the SQL template from the values bound at execution time, maximising reuse of SQLite's prepared-statement cache. Use `col(_:)` to reference columns and `Param<T>` for values supplied at the call site.

```swift
let products = TableName("products")
let idCol    = col("id")
let nameCol  = col("name")
let priceCol = col("price")

// Query — reusable template with named parameters
let maxPrice = Param<Double>("maxPrice")

let cheapProducts = Select(.all)
    .from(products)
    .where(priceCol < maxPrice)
    .orderBy(priceCol)

let rows = try await db.query(cheapProducts, maxPrice.set(50.0))

// Update — reusable template with named parameters
let newPrice = Param<Double>("newPrice")
let targetId = Param<Int>("id")

let updatePrice = Update(products)
    .set(priceCol, to: newPrice)
    .where(idCol == targetId)

try await db.execute(updatePrice, newPrice.set(39.99), targetId.set(7))
```

### Entity Protocol

Conform a `Codable` struct to `Entity` to get one-line save and fetch semantics. When the primary key is `Int?`, SQLite assigns the rowid on insert and the returned copy carries the generated value.

```swift
struct Product: Entity {
    static let tableName  = TableName("products")
    static let primaryKey: WritableKeyPath<Product, Int?> & Sendable = \.id

    var id:    Int?
    var name:  String
    var price: Double
}

// Insert — id is nil, SQLite assigns it
var product = Product(id: nil, name: "Widget", price: 9.99)
product = try await db.save(product)     // product.id is now Optional(1)

// Update — id is set, triggers an upsert
product.price = 7.49
try await db.save(product)

// Fetch all rows
let allProducts = try await db.fetch(Product.self)

// Fetch with an expression predicate
let affordable = try await db.fetch(
    Product.self,
    where: col("price") <= 10.0
)

// Fetch by primary key
if let found = try await db.fetchOne(Product.self, id: 1) {
    print(found.name)
}

// Delete by primary key, or by predicate; both return the number of rows deleted
try await db.delete(Product.self, id: 1)
try await db.delete(Product.self, where: col("price") > 100.0)
```

Saving an array (`db.save([a, b, c])`) is atomic: if one record fails, none are saved.

### Transactions

`transaction` runs a synchronous body inside `BEGIN` … `COMMIT`, rolling back if the body throws. The `Connection` it passes has the same raw-SQL, query-builder, and entity methods as `Database`, so they can all be combined atomically. Reads inside the body see its own uncommitted writes.

```swift
let order = try await db.transaction { conn in
    let order = try conn.save(Order(id: nil, customer: "Alice"))
    try conn.save(skus.map { LineItem(id: nil, orderID: order.id!, sku: $0) })
    try conn.execute("UPDATE customers SET orders = orders + 1 WHERE name = ?", "Alice")
    return order
}
```

Use `conn.savepoint { ... }` inside a transaction for a step that can fail and be undone without abandoning the rest. A batch `save([...])` already uses a savepoint, so it nests safely inside a transaction.

---

## Migrations

SqlCipherKit includes a lightweight migration system for evolving your database schema over time. Each migration is a `struct` (or `class`) that conforms to the `Migration` protocol by providing a unique string `id`, an `up(_:)` method that applies the change, and an optional `down(_:)` method that reverses it.

```swift
struct CreateProductsTable: Migration {
    let id = "001-create-products"

    func up(_ ctx: MigrationContext) throws {
        try ctx.execute(
            CreateTable(TableName("products"))
                .column("id",    .integer, .primaryKey)
                .column("name",  .text,    .notNull)
                .column("price", .real,    .notNull)
        )
    }

    func down(_ ctx: MigrationContext) throws {
        try ctx.execute(DropTable(TableName("products")))
    }
}

struct AddDiscountColumn: Migration {
    let id = "002-add-discount"

    func up(_ ctx: MigrationContext) throws {
        try ctx.execute(
            AlterTable(TableName("products"), addColumn: "discount", .real, .default(0.0))
        )
    }

    func down(_ ctx: MigrationContext) throws {
        try ctx.execute(
            AlterTable(TableName("products"), dropColumn: "discount")
        )
    }
}
```

### Applying Migrations

Call `migrate(_:)` with an ordered array of all your migrations. The method creates a `_migrations` tracking table on first use and skips any migration whose `id` is already recorded there. Each pending migration runs inside its own transaction — if one fails, it is rolled back and no further migrations are applied.

```swift
let migrations: [any Migration] = [
    CreateProductsTable(),
    AddDiscountColumn(),
]

try await db.migrate(migrations)
```

It is safe to call `migrate(_:)` every time the app launches. Already-applied migrations are no-ops.

### Rolling Back

To reverse applied migrations, call `rollback(to:using:)` with the `id` of the earliest migration you want to undo. Every migration applied at or after that point is reversed in reverse order, each in its own transaction.

```swift
// Undo AddDiscountColumn and everything applied after it.
try await db.rollback(to: "002-add-discount", using: migrations)
```

---

## Notices

SqlCipherKit bundles the SQLCipher amalgamation source (`Sources/CSqlCipher/sqlite3.c`), which is distributed under a BSD-style license by Zetetic, LLC. See the [NOTICE](NOTICE) file for the full copyright and license text required by that license, and [LICENSE](LICENSE) for the MIT license that covers the Swift source in this repository.
