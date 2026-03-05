import Foundation
import Testing

@testable import SqlCipherKit

// MARK: - Helpers

private func tempDBPath() -> String {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tablerecord-test-\(UUID().uuidString).db")
        .path
}

private func makeDB() throws -> Database {
    try Database(path: tempDBPath(), key: "testkey")
}

// MARK: - Fixture model types

/// Simple model — caller-supplied Int primary key.
private struct Widget: TableRecord, Equatable {
    static let tableName = TableName("widgets")
    static let primaryKey = \Widget.id
    var id: Int
    var name: String
    var price: Double
}

/// Auto-increment integer PK.
private struct Note: TableRecord, Equatable {
    static let tableName = TableName("notes")
    static let primaryKey = \Note.id
    var id: Int?
    var title: String
    var body: String
}

/// String primary key (UUID string).
private struct Tag: TableRecord, Equatable {
    static let tableName = TableName("tags")
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
    static let tableName = TableName("events")
    static let primaryKey = \Event.id
    var id: Int
    var name: String
    var notes: String?
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
        try await db.execute(
            CreateTable(TableName("widgets"))
                .column("id", .integer, .primaryKey)
                .column("name", .text, .notNull)
                .column("price", .real, .notNull))

        let w = Widget(id: 1, name: "Bolt", price: 0.99)
        try await db.save(w)

        let rows = try await db.query("SELECT id, name, price FROM widgets")
        #expect(rows.count == 1)
        #expect(rows[0]["name"] == .text("Bolt"))
    }

    @Test("save returns record unchanged for non-autoincrement PK")
    func returnsUnchanged() async throws {
        let db = try makeDB()
        try await db.execute(
            CreateTable(TableName("widgets"))
                .column("id", .integer, .primaryKey)
                .column("name", .text, .notNull)
                .column("price", .real, .notNull))

        let w = Widget(id: 42, name: "Nut", price: 0.25)
        let saved = try await db.save(w)
        #expect(saved == w)
    }

    @Test("save upserts an existing record in-place")
    func upsertsExistingRecord() async throws {
        let db = try makeDB()
        try await db.execute(
            CreateTable(TableName("widgets"))
                .column("id", .integer, .primaryKey)
                .column("name", .text, .notNull)
                .column("price", .real, .notNull))

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
        try await db.execute(
            CreateTable(TableName("widgets"))
                .column("id", .integer, .primaryKey)
                .column("name", .text, .notNull)
                .column("price", .real, .notNull))

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
        try await db.execute(
            CreateTable(TableName("notes"))
                .column("id", .integer, .autoIncrement)
                .column("title", .text, .notNull)
                .column("body", .text, .notNull))

        var note = Note(id: nil, title: "Hello", body: "World")
        note = try await db.save(note)
        #expect(note.id != nil)
        #expect(note.id == 1)
    }

    @Test("successive saves assign incrementing rowids")
    func incrementingRowids() async throws {
        let db = try makeDB()
        try await db.execute(
            CreateTable(TableName("notes"))
                .column("id", .integer, .autoIncrement)
                .column("title", .text, .notNull)
                .column("body", .text, .notNull))

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
        try await db.execute(
            CreateTable(TableName("notes"))
                .column("id", .integer, .autoIncrement)
                .column("title", .text, .notNull)
                .column("body", .text, .notNull))

        // Should compile without warning due to @discardableResult
        try await db.save(Note(id: nil, title: "Ignored", body: ""))

        let count: Int? = try await db.scalarQuery("SELECT COUNT(*) FROM notes", as: Int.self)
        #expect(count == 1)
    }

    @Test("batch save with auto-increment returns all updated copies")
    func batchAutoIncrement() async throws {
        let db = try makeDB()
        try await db.execute(
            CreateTable(TableName("notes"))
                .column("id", .integer, .autoIncrement)
                .column("title", .text, .notNull)
                .column("body", .text, .notNull))

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
        try await db.execute(
            CreateTable(TableName("tags"))
                .column("tag_id", .text, .primaryKey)
                .column("label", .text, .notNull))

        let tag = Tag(tagId: "swift", label: "Swift language")
        try await db.save(tag)

        let rows = try await db.query("SELECT tag_id, label FROM tags")
        #expect(rows.count == 1)
        #expect(rows[0]["tag_id"] == .text("swift"))
    }

    @Test("save upserts an existing string-keyed record")
    func upsertsStringPK() async throws {
        let db = try makeDB()
        try await db.execute(
            CreateTable(TableName("tags"))
                .column("tag_id", .text, .primaryKey)
                .column("label", .text, .notNull))

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
        try await db.execute(
            CreateTable(TableName("events"))
                .column("id", .integer, .primaryKey)
                .column("name", .text, .notNull)
                .column("notes", .text))

        try await db.save(Event(id: 1, name: "Launch", notes: nil))

        let rows = try await db.query("SELECT notes FROM events WHERE id = 1")
        #expect(rows.count == 1)
        #expect(rows[0]["notes"] == .null)
    }

    @Test("non-nil optional column saved with value")
    func nonNilOptionalColumn() async throws {
        let db = try makeDB()
        try await db.execute(
            CreateTable(TableName("events"))
                .column("id", .integer, .primaryKey)
                .column("name", .text, .notNull)
                .column("notes", .text))

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
        try await db.execute(
            CreateTable(TableName("widgets"))
                .column("id", .integer, .primaryKey)
                .column("name", .text, .notNull)
                .column("price", .real, .notNull))

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
