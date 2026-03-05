import Foundation
import Testing

@testable import SqlCipherKit

// MARK: - Helpers

private func makeDB() throws -> Database {
    try Database(path: tempDBPath(), key: "testkey")
}

// MARK: - Schema namespaces
//
// Caseless enums that hold static TableName / ColumnRef constants and a DDL
// factory for each fixture model.  Avoids repeating string literals across
// every test that needs to create or query the same table.

private enum WidgetSchema {
    static let table = TableName("widgets")
    static let id = ColumnRef("id")
    static let name = ColumnRef("name")
    static let price = ColumnRef("price")

    static func createTable() -> CreateTable {
        CreateTable(table)
            .column(id.name, .integer, .primaryKey)
            .column(name.name, .text, .notNull)
            .column(price.name, .real, .notNull)
    }
}

private enum NoteSchema {
    static let table = TableName("notes")
    static let id = ColumnRef("id")
    static let title = ColumnRef("title")
    static let body = ColumnRef("body")

    static func createTable() -> CreateTable {
        CreateTable(table)
            .column(id.name, .integer, .autoIncrement)
            .column(title.name, .text, .notNull)
            .column(body.name, .text, .notNull)
    }
}

private enum TagSchema {
    static let table = TableName("tags")
    static let tagId = ColumnRef("tag_id")
    static let label = ColumnRef("label")

    static func createTable() -> CreateTable {
        CreateTable(table)
            .column(tagId.name, .text, .primaryKey)
            .column(label.name, .text, .notNull)
    }
}

private enum EventSchema {
    static let table = TableName("events")
    static let id = ColumnRef("id")
    static let name = ColumnRef("name")
    static let notes = ColumnRef("notes")

    static func createTable() -> CreateTable {
        CreateTable(table)
            .column(id.name, .integer, .primaryKey)
            .column(name.name, .text, .notNull)
            .column(notes.name, .text)
    }
}

private enum CatalogSchema {
    static let table = TableName("catalogs")
    static let id = ColumnRef("id")
    static let name = ColumnRef("name")
    static let tags = ColumnRef("tags")
    static let ratings = ColumnRef("ratings")

    static func createTable() -> CreateTable {
        CreateTable(table)
            .column(id.name, .integer, .primaryKey)
            .column(name.name, .text, .notNull)
            .column(tags.name, .text, .notNull)  // JSON array
            .column(ratings.name, .text)  // JSON dict, nullable
    }
}

// MARK: - Fixture model types

/// Simple model — caller-supplied Int primary key.
private struct Widget: TableRecord, Equatable {
    static let tableName = WidgetSchema.table
    static let primaryKey = \Widget.id
    var id: Int
    var name: String
    var price: Double
}

/// Auto-increment integer PK.
private struct Note: TableRecord, Equatable {
    static let tableName = NoteSchema.table
    static let primaryKey = \Note.id
    var id: Int?
    var title: String
    var body: String
}

/// String primary key (UUID string).
private struct Tag: TableRecord, Equatable {
    static let tableName = TagSchema.table
    static let primaryKeyName = "tag_id"
    static let primaryKey = \Tag.tagId
    var tagId: String
    var label: String

    enum CodingKeys: String, CodingKey {
        case tagId = "tag_id"
        case label
    }
}

/// Optional non-PK columns.
private struct Event: TableRecord, Equatable {
    static let tableName = EventSchema.table
    static let primaryKey = \Event.id
    var id: Int
    var name: String
    var notes: String?
}

/// Complex column types — array and optional dictionary stored as JSON.
private struct Catalog: TableRecord, Equatable {
    static let tableName = CatalogSchema.table
    static let primaryKey = \Catalog.id
    var id: Int
    var name: String
    var tags: [String]
    var ratings: [String: Double]?
}

// MARK: - RowEncoder unit tests

@Suite("RowEncoder – unit")
struct RowEncoderTests {

    @Test("Encodes all primitive types")
    func primitiveTypes() throws {
        struct S: Encodable {
            let a: Bool
            let b: Int
            let c: Double
            let d: String
            let e: Float
        }
        let cols = try RowEncoder().encode(S(a: true, b: 42, c: 3.14, d: "hi", e: 1.5))
        #expect(cols.count == 5)
        #expect(cols[0] == (key: "a", value: .integer(1)))
        #expect(cols[1] == (key: "b", value: .integer(42)))
        #expect(cols[2] == (key: "c", value: .real(3.14)))
        #expect(cols[3] == (key: "d", value: .text("hi")))
        #expect(cols[4] == (key: "e", value: .real(Double(Float(1.5)))))
    }

    @Test("Encodes Data as blob")
    func dataBlob() throws {
        struct S: Encodable { let x: Data }
        let cols = try RowEncoder().encode(S(x: Data([0xAB, 0xCD])))
        #expect(cols[0] == (key: "x", value: .blob(Data([0xAB, 0xCD]))))
    }

    @Test("Encodes UUID as text")
    func uuidText() throws {
        struct S: Encodable { let id: UUID }
        let uuid = UUID()
        let cols = try RowEncoder().encode(S(id: uuid))
        #expect(cols[0] == (key: "id", value: .text(uuid.uuidString)))
    }

    @Test("Encodes nil Optional as .null")
    func nilOptional() throws {
        struct S: Encodable { let x: Int? }
        let cols = try RowEncoder().encode(S(x: nil))
        #expect(cols[0] == (key: "x", value: .null))
    }

    @Test("Encodes non-nil Optional as inner value")
    func nonNilOptional() throws {
        struct S: Encodable { let x: Int? }
        let cols = try RowEncoder().encode(S(x: 99))
        #expect(cols[0] == (key: "x", value: .integer(99)))
    }

    @Test("Encodes String enum via single value container")
    func stringEnum() throws {
        enum Status: String, Encodable { case active, inactive }
        struct S: Encodable { let status: Status }
        let cols = try RowEncoder().encode(S(status: .active))
        #expect(cols[0] == (key: "status", value: .text("active")))
    }

    @Test("Encodes Int enum via single value container")
    func intEnum() throws {
        enum Priority: Int, Encodable {
            case low = 1
            case high = 2
        }
        struct S: Encodable { let p: Priority }
        let cols = try RowEncoder().encode(S(p: .high))
        #expect(cols[0] == (key: "p", value: .integer(2)))
    }

    @Test("Preserves field declaration order")
    func fieldOrder() throws {
        struct S: Encodable {
            let c: String
            let a: String
            let b: String
        }
        let cols = try RowEncoder().encode(S(c: "c", a: "a", b: "b"))
        #expect(cols.map(\.key) == ["c", "a", "b"])
    }

    @Test("Date – secondsSince1970 strategy")
    func dateSecondsSince1970() throws {
        struct S: Encodable { let ts: Date }
        let date = Date(timeIntervalSince1970: 1_000_000)
        let enc = RowEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        let cols = try enc.encode(S(ts: date))
        #expect(cols[0] == (key: "ts", value: .real(1_000_000)))
    }

    @Test("Date – iso8601 strategy encodes as text")
    func dateISO8601() throws {
        struct S: Encodable { let ts: Date }
        let enc = RowEncoder()
        if #available(macOS 10.12, *) {
            enc.dateEncodingStrategy = .iso8601
            let date = Date(timeIntervalSince1970: 0)
            let cols = try enc.encode(S(ts: date))
            if case .text(let s) = cols[0].value {
                #expect(s.contains("1970"))
            } else {
                #expect(Bool(false), "Expected .text for iso8601 date")
            }
        }
    }

    @Test("CodingKeys rename is respected")
    func codingKeys() throws {
        struct S: Encodable {
            var userId: Int
            var fullName: String
            enum CodingKeys: String, CodingKey {
                case userId = "user_id"
                case fullName = "full_name"
            }
        }
        let cols = try RowEncoder().encode(S(userId: 1, fullName: "Alice"))
        #expect(cols[0].key == "user_id")
        #expect(cols[1].key == "full_name")
    }
}

// MARK: - Optional: SQLConvertible unit tests

@Suite("Optional: SQLConvertible")
struct OptionalSQLConvertibleTests {

    @Test("nil encodes as .null")
    func nilToNull() {
        let v: Int? = nil
        #expect(v.sqlValue == .null)
    }

    @Test("non-nil encodes as inner value")
    func nonNilToValue() {
        let v: Int? = 42
        #expect(v.sqlValue == .integer(42))
    }

    @Test("from(.null) returns .some(.none)")
    func fromNull() {
        let result = Int?.from(sqlValue: .null)
        // result is Optional<Optional<Int>>
        // .some(.none) means "successfully decoded a nil"
        #expect(result != nil)  // outer Some — decoding succeeded
        #expect(result! == nil)  // inner None — the value is SQL NULL
    }

    @Test("from(integer) returns .some(.some(value))")
    func fromInteger() {
        let result = Int?.from(sqlValue: .integer(7))
        #expect(result == .some(.some(7)))
    }

    @Test("from mismatched type returns nil (decode failure)")
    func fromMismatch() {
        let result = Int?.from(sqlValue: .text("bad"))
        // Outer nil means "could not decode" — distinct from SQL NULL
        #expect(result == nil)
    }
}

// MARK: - Integration: save with caller-supplied PK

@Suite("Database.save – caller-supplied PK")
struct SaveCallerPKTests {

    @Test("save inserts a new record")
    func insertsNewRecord() async throws {
        let db = try makeDB()
        try await db.execute(WidgetSchema.createTable())

        let w = Widget(id: 1, name: "Bolt", price: 0.99)
        try await db.save(w)

        let rows = try await db.query("SELECT id, name, price FROM widgets")
        #expect(rows.count == 1)
        #expect(rows[0]["name"] == .text("Bolt"))
    }

    @Test("save returns record unchanged for non-autoincrement PK")
    func returnsUnchanged() async throws {
        let db = try makeDB()
        try await db.execute(WidgetSchema.createTable())

        let w = Widget(id: 42, name: "Nut", price: 0.25)
        let saved = try await db.save(w)
        #expect(saved == w)
    }

    @Test("save upserts an existing record in-place")
    func upsertsExistingRecord() async throws {
        let db = try makeDB()
        try await db.execute(WidgetSchema.createTable())

        try await db.save(Widget(id: 1, name: "Bolt", price: 0.99))
        try await db.save(Widget(id: 1, name: "Bolt Pro", price: 1.49))

        let rows = try await db.query("SELECT * FROM widgets")
        #expect(rows.count == 1)
        #expect(rows[0]["name"] == .text("Bolt Pro"))
        #expect(rows[0]["price"] == .real(1.49))
    }

    @Test("save multiple records with upsert semantics")
    func multipleUpserts() async throws {
        let db = try makeDB()
        try await db.execute(WidgetSchema.createTable())

        let widgets = [
            Widget(id: 1, name: "A", price: 1.0),
            Widget(id: 2, name: "B", price: 2.0),
            Widget(id: 3, name: "C", price: 3.0),
        ]
        try await db.save(widgets)

        let rows = try await db.query("SELECT id FROM widgets ORDER BY id")
        #expect(rows.count == 3)
    }
}

// MARK: - Integration: save with auto-increment PK

@Suite("Database.save – auto-increment PK")
struct SaveAutoIncrementTests {

    @Test("save assigns rowid and returns it in a copy")
    func assignsRowid() async throws {
        let db = try makeDB()
        try await db.execute(NoteSchema.createTable())

        var note = Note(id: nil, title: "Hello", body: "World")
        note = try await db.save(note)
        #expect(note.id != nil)
        #expect(note.id == 1)
    }

    @Test("successive saves assign incrementing rowids")
    func incrementingRowids() async throws {
        let db = try makeDB()
        try await db.execute(NoteSchema.createTable())

        let n1 = try await db.save(Note(id: nil, title: "A", body: ""))
        let n2 = try await db.save(Note(id: nil, title: "B", body: ""))
        let n3 = try await db.save(Note(id: nil, title: "C", body: ""))

        #expect(n1.id == 1)
        #expect(n2.id == 2)
        #expect(n3.id == 3)
    }

    @Test("discardable result: save without capturing return value")
    func discardableResult() async throws {
        let db = try makeDB()
        try await db.execute(NoteSchema.createTable())

        // Should compile without warning due to @discardableResult
        try await db.save(Note(id: nil, title: "Ignored", body: ""))

        let count: Int? = try await db.scalarQuery("SELECT COUNT(*) FROM notes", as: Int.self)
        #expect(count == 1)
    }

    @Test("batch save with auto-increment returns all updated copies")
    func batchAutoIncrement() async throws {
        let db = try makeDB()
        try await db.execute(NoteSchema.createTable())

        let notes = [
            Note(id: nil, title: "X", body: ""),
            Note(id: nil, title: "Y", body: ""),
        ]
        let saved = try await db.save(notes)
        #expect(saved[0].id == 1)
        #expect(saved[1].id == 2)
    }
}

// MARK: - Integration: String primary key

@Suite("Database.save – String PK")
struct SaveStringPKTests {

    @Test("save inserts with custom string primary key")
    func insertsStringPK() async throws {
        let db = try makeDB()
        try await db.execute(TagSchema.createTable())

        let tag = Tag(tagId: "swift", label: "Swift language")
        try await db.save(tag)

        let rows = try await db.query("SELECT tag_id, label FROM tags")
        #expect(rows.count == 1)
        #expect(rows[0]["tag_id"] == .text("swift"))
    }

    @Test("save upserts an existing string-keyed record")
    func upsertsStringPK() async throws {
        let db = try makeDB()
        try await db.execute(TagSchema.createTable())

        try await db.save(Tag(tagId: "swift", label: "Swift"))
        try await db.save(Tag(tagId: "swift", label: "Swift Language"))

        let rows = try await db.query("SELECT label FROM tags")
        #expect(rows.count == 1)
        #expect(rows[0]["label"] == .text("Swift Language"))
    }
}

// MARK: - Integration: optional non-PK columns

@Suite("Database.save – optional columns")
struct SaveOptionalColumnsTests {

    @Test("nil optional column saved as NULL")
    func nilOptionalColumn() async throws {
        let db = try makeDB()
        try await db.execute(EventSchema.createTable())

        try await db.save(Event(id: 1, name: "Launch", notes: nil))

        let rows = try await db.query("SELECT notes FROM events WHERE id = 1")
        #expect(rows.count == 1)
        #expect(rows[0]["notes"] == .null)
    }

    @Test("non-nil optional column saved with value")
    func nonNilOptionalColumn() async throws {
        let db = try makeDB()
        try await db.execute(EventSchema.createTable())

        try await db.save(Event(id: 1, name: "Launch", notes: "Big day"))

        let rows = try await db.query("SELECT notes FROM events WHERE id = 1")
        #expect(rows[0]["notes"] == .text("Big day"))
    }
}

// MARK: - Integration: batch transaction atomicity

@Suite("Database.save – batch atomicity")
struct SaveBatchAtomicityTests {

    @Test("batch save rolls back all records on error")
    func rollsBackOnError() async throws {
        let db = try makeDB()
        try await db.execute(WidgetSchema.createTable())

        // First widget is fine; use a duplicate PK for the second to cause an error on insert.
        // Actually ON CONFLICT upserts, so let's cause a NOT NULL violation instead.
        // We'll test by saving into a table that has a UNIQUE constraint on name.
        try await db.execute("CREATE UNIQUE INDEX widgets_name ON widgets (name)")

        let widgets = [
            Widget(id: 1, name: "Unique", price: 1.0),
            Widget(id: 2, name: "Unique", price: 2.0),  // name conflict → error
        ]

        await #expect(throws: (any Error).self) {
            try await db.save(widgets)
        }

        // Neither record should exist.
        let count: Int? = try await db.scalarQuery("SELECT COUNT(*) FROM widgets", as: Int.self)
        #expect(count == 0)
    }
}

// MARK: - Integration: fetch helpers

private func makeWidgetsDB() async throws -> Database {
    let db = try makeDB()
    try await db.execute(WidgetSchema.createTable())
    try await db.save([
        Widget(id: 1, name: "Bolt", price: 0.99),
        Widget(id: 2, name: "Nut", price: 0.49),
        Widget(id: 3, name: "Washer", price: 0.25),
        Widget(id: 4, name: "Screw", price: 1.49),
    ])
    return db
}

@Suite("Database.fetch – all rows")
struct FetchAllTests {

    @Test("fetch returns all rows")
    func fetchAll() async throws {
        let db = try await makeWidgetsDB()
        let widgets: [Widget] = try await db.fetch(Widget.self)
        #expect(widgets.count == 4)
    }

    @Test("fetch returns empty array when table is empty")
    func fetchEmpty() async throws {
        let db = try makeDB()
        try await db.execute(WidgetSchema.createTable())
        let widgets: [Widget] = try await db.fetch(Widget.self)
        #expect(widgets.isEmpty)
    }
}

@Suite("Database.fetch – WHERE predicate")
struct FetchWhereTests {

    @Test("fetch with literal predicate filters rows")
    func fetchWithLiteral() async throws {
        let db = try await makeWidgetsDB()
        let cheap: [Widget] = try await db.fetch(Widget.self, where: WidgetSchema.price < 0.50)
        #expect(cheap.count == 2)
        #expect(cheap.allSatisfy { $0.price < 0.50 })
    }

    @Test("fetch with AND predicate")
    func fetchWithAnd() async throws {
        let db = try await makeWidgetsDB()
        let results: [Widget] = try await db.fetch(
            Widget.self, where: WidgetSchema.price >= 0.49 && WidgetSchema.price <= 0.99)
        #expect(results.count == 2)
    }

    @Test("fetch with named Param")
    func fetchWithParam() async throws {
        let db = try await makeWidgetsDB()
        let minPrice = Param<Double>("minPrice")
        let results: [Widget] = try await db.fetch(
            Widget.self, where: WidgetSchema.price >= minPrice, minPrice.set(0.98))
        #expect(results.count == 2)  // Bolt (0.99) and Screw (1.49)
        #expect(results.allSatisfy { $0.price >= 0.98 })
    }

    @Test("fetch with predicate returns empty when no match")
    func fetchNoMatch() async throws {
        let db = try await makeWidgetsDB()
        let results: [Widget] = try await db.fetch(Widget.self, where: WidgetSchema.price > 100.0)
        #expect(results.isEmpty)
    }
}

@Suite("Database.fetchOne – by primary key")
struct FetchOneTests {

    @Test("fetchOne returns the matching record")
    func fetchOneFound() async throws {
        let db = try await makeWidgetsDB()
        let widget = try await db.fetchOne(Widget.self, id: 2)
        #expect(widget?.name == "Nut")
    }

    @Test("fetchOne returns nil when id is absent")
    func fetchOneNotFound() async throws {
        let db = try await makeWidgetsDB()
        let widget = try await db.fetchOne(Widget.self, id: 99)
        #expect(widget == nil)
    }

    @Test("fetchOne works with string primary key")
    func fetchOneStringPK() async throws {
        let db = try makeDB()
        try await db.execute(TagSchema.createTable())
        try await db.save(Tag(tagId: "swift", label: "Swift Language"))
        try await db.save(Tag(tagId: "sql", label: "SQL"))

        let tag = try await db.fetchOne(Tag.self, id: "swift")
        #expect(tag?.label == "Swift Language")
    }

    @Test("fetchOne with auto-increment PK")
    func fetchOneAutoIncrement() async throws {
        let db = try makeDB()
        try await db.execute(NoteSchema.createTable())
        let saved = try await db.save(Note(id: nil, title: "Hello", body: "World"))
        let fetched = try await db.fetchOne(Note.self, id: saved.id)
        #expect(fetched?.title == "Hello")
    }
}

// MARK: - ComplexColumnStrategy tests

@Suite("Database – complex column strategy (JSON)")
struct ComplexColumnTests {

    @Test("Array column round-trips via JSON")
    func arrayColumnRoundTrip() async throws {
        let db = try makeDB()
        try await db.execute(CatalogSchema.createTable())
        let original = Catalog(id: 1, name: "Tech", tags: ["swift", "sql", "ios"], ratings: nil)
        try await db.save(original)
        let fetched = try await db.fetchOne(Catalog.self, id: 1)
        #expect(fetched == original)
    }

    @Test("Dictionary column round-trips via JSON")
    func dictionaryColumnRoundTrip() async throws {
        let db = try makeDB()
        try await db.execute(CatalogSchema.createTable())
        let original = Catalog(
            id: 2, name: "Lang", tags: ["rust"],
            ratings: ["performance": 9.5, "ergonomics": 8.0])
        try await db.save(original)
        let fetched = try await db.fetchOne(Catalog.self, id: 2)
        #expect(fetched == original)
    }

    @Test("Optional complex column stores nil as NULL")
    func optionalComplexColumnNil() async throws {
        let db = try makeDB()
        try await db.execute(CatalogSchema.createTable())
        let original = Catalog(id: 3, name: "Empty", tags: [], ratings: nil)
        try await db.save(original)
        let fetched = try await db.fetchOne(Catalog.self, id: 3)
        #expect(fetched?.ratings == nil)
    }

    @Test("nil strategy throws on complex type")
    func nilStrategyThrows() async throws {
        let db = try Database(path: tempDBPath(), key: "testkey", complexColumnStrategy: nil)
        try await db.execute(CatalogSchema.createTable())
        let catalog = Catalog(id: 4, name: "Fail", tags: ["a", "b"], ratings: nil)
        await #expect(throws: (any Error).self) {
            try await db.save(catalog)
        }
    }
}
