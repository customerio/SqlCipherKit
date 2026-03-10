import Foundation
import Testing

@testable import SqlCipherKit

// MARK: - Helpers

/// Returns a fresh in-memory–style (temp file) database.
private func makeDB() throws -> Database {
    try Database(path: tempDBPath(), key: "testkey")
}

// MARK: - Row factory helpers

/// Constructs a bare ``Row`` for unit-testing the decoder without a real DB.
private func row(_ pairs: (String, Value)...) -> Row {
    var index: [String: Int] = [:]
    var values: [Value] = []
    for (idx, pair) in pairs.enumerated() {
        index[pair.0] = idx
        values.append(pair.1)
    }
    return Row(columnIndex: index, values: values)
}

// MARK: - Unit tests: primitive types

@Suite("RowDecoder – primitive types")
struct RowDecoderPrimitivesTests {

    struct AllPrimitives: Decodable {
        let flag: Bool
        let count: Int
        let i32: Int32
        let i64: Int64
        let score: Double
        let flt: Float
        let label: String
        let blob: Data
    }

    @Test("Decodes all non-optional primitives from a single row")
    func decodeAllPrimitives() throws {
        let r = row(
            ("flag", .integer(1)),
            ("count", .integer(42)),
            ("i32", .integer(100)),
            ("i64", .integer(Int64.max)),
            ("score", .real(3.14)),
            ("flt", .real(1.5)),
            ("label", .text("hello")),
            ("blob", .blob(Data([0x01, 0x02, 0x03])))
        )
        let result = try RowDecoder().decode(AllPrimitives.self, from: r)
        #expect(result.flag == true)
        #expect(result.count == 42)
        #expect(result.i32 == 100)
        #expect(result.i64 == Int64.max)
        #expect(result.score == 3.14)
        #expect(result.flt == 1.5)
        #expect(result.label == "hello")
        #expect(result.blob == Data([0x01, 0x02, 0x03]))
    }

    @Test("Bool false decoded from integer 0")
    func boolFalse() throws {
        struct S: Decodable { let v: Bool }
        let result = try RowDecoder().decode(S.self, from: row(("v", .integer(0))))
        #expect(result.v == false)
    }

    @Test("Decodes integer column as Double")
    func integerAsDouble() throws {
        struct S: Decodable { let v: Double }
        let result = try RowDecoder().decode(S.self, from: row(("v", .integer(7))))
        #expect(result.v == 7.0)
    }

    @Test("Decodes integer column as Float")
    func integerAsFloat() throws {
        struct S: Decodable { let v: Float }
        let result = try RowDecoder().decode(S.self, from: row(("v", .integer(3))))
        #expect(result.v == 3.0)
    }

    @Test("Decodes UInt types from non-negative integers")
    func unsignedInts() throws {
        struct S: Decodable {
            let a: UInt
            let b: UInt8
            let c: UInt16
            let d: UInt32
        }
        let r = row(
            ("a", .integer(1)), ("b", .integer(255)), ("c", .integer(1000)), ("d", .integer(99999)))
        let result = try RowDecoder().decode(S.self, from: r)
        #expect(result.a == 1)
        #expect(result.b == 255)
        #expect(result.c == 1000)
        #expect(result.d == 99999)
    }
}

// MARK: - Unit tests: optionals

@Suite("RowDecoder – optionals")
struct RowDecoderOptionalsTests {

    struct WithOptionals: Decodable {
        let name: String
        let score: Double?
        let notes: String?
    }

    @Test("Optional column with .null decodes to nil")
    func nullColumnDecodesToNil() throws {
        let r = row(("name", .text("Alice")), ("score", .null), ("notes", .null))
        let result = try RowDecoder().decode(WithOptionals.self, from: r)
        #expect(result.name == "Alice")
        #expect(result.score == nil)
        #expect(result.notes == nil)
    }

    @Test("Optional column with absent key decodes to nil")
    func absentColumnDecodesToNil() throws {
        // Only "name" present; score and notes are absent.
        let r = row(("name", .text("Bob")))
        let result = try RowDecoder().decode(WithOptionals.self, from: r)
        #expect(result.name == "Bob")
        #expect(result.score == nil)
        #expect(result.notes == nil)
    }

    @Test("Optional column with real value decodes to non-nil")
    func presentOptional() throws {
        let r = row(("name", .text("Carol")), ("score", .real(9.5)), ("notes", .text("great")))
        let result = try RowDecoder().decode(WithOptionals.self, from: r)
        #expect(result.score == 9.5)
        #expect(result.notes == "great")
    }
}

// MARK: - Unit tests: UUID

@Suite("RowDecoder – UUID")
struct RowDecoderUUIDTests {

    struct S: Decodable { let id: UUID }

    @Test("Decodes a UUID from a text column")
    func decodesUUID() throws {
        let uuid = UUID()
        let r = row(("id", .text(uuid.uuidString)))
        let result = try RowDecoder().decode(S.self, from: r)
        #expect(result.id == uuid)
    }

    @Test("Throws on invalid UUID string")
    func invalidUUIDThrows() throws {
        let r = row(("id", .text("not-a-uuid")))
        #expect(throws: (any Error).self) {
            try RowDecoder().decode(S.self, from: r)
        }
    }
}

// MARK: - Unit tests: Date decoding strategies

@Suite("RowDecoder – Date strategies")
struct RowDecoderDateTests {

    struct W: Decodable { let ts: Date }

    /// Reference timestamp: 2024-03-15 12:00:00 UTC
    static let refDate: Date = {
        var c = DateComponents()
        c.year = 2024
        c.month = 3
        c.day = 15
        c.hour = 12
        c.minute = 0
        c.second = 0
        c.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: c)!
    }()

    @Test("secondsSince1970 from real column")
    func secondsSince1970() throws {
        var decoder = RowDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let r = row(("ts", .real(Self.refDate.timeIntervalSince1970)))
        let result = try decoder.decode(W.self, from: r)
        #expect(abs(result.ts.timeIntervalSince1970 - Self.refDate.timeIntervalSince1970) < 0.001)
    }

    @Test("secondsSince1970 from integer column")
    func secondsSince1970FromInt() throws {
        var decoder = RowDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let r = row(("ts", .integer(Int64(Self.refDate.timeIntervalSince1970))))
        let result = try decoder.decode(W.self, from: r)
        #expect(abs(result.ts.timeIntervalSince1970 - Self.refDate.timeIntervalSince1970) < 1.0)
    }

    @Test("millisecondsSince1970 from real column")
    func milliseconds() throws {
        var decoder = RowDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let ms = Self.refDate.timeIntervalSince1970 * 1000
        let r = row(("ts", .real(ms)))
        let result = try decoder.decode(W.self, from: r)
        #expect(abs(result.ts.timeIntervalSince1970 - Self.refDate.timeIntervalSince1970) < 0.001)
    }

    @available(macOS 10.12, iOS 10.0, tvOS 10.0, watchOS 3.0, *)
    @Test("iso8601 text column")
    func iso8601() throws {
        var decoder = RowDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let str = ISO8601DateFormatter().string(from: Self.refDate)
        let r = row(("ts", .text(str)))
        let result = try decoder.decode(W.self, from: r)
        #expect(abs(result.ts.timeIntervalSince1970 - Self.refDate.timeIntervalSince1970) < 1.0)
    }

    @Test("formatted DateFormatter text column")
    func formatted() throws {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        var decoder = RowDecoder()
        decoder.dateDecodingStrategy = .formatted(fmt)
        let r = row(("ts", .text("2024-03-15")))
        let result = try decoder.decode(W.self, from: r)
        let cal = Calendar(identifier: .gregorian)
        let tz = TimeZone(identifier: "UTC")!
        let comps = cal.dateComponents(in: tz, from: result.ts)
        #expect(comps.year == 2024)
        #expect(comps.month == 3)
        #expect(comps.day == 15)
    }

    @Test("custom strategy returns correct Date")
    func custom() throws {
        var decoder = RowDecoder()
        decoder.dateDecodingStrategy = .custom { value in
            guard case .integer(let i) = value else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad"))
            }
            return Date(timeIntervalSince1970: Double(i) * 60)  // minutes since epoch
        }
        let r = row(("ts", .integer(1000)))  // 1000 minutes since epoch
        let result = try decoder.decode(W.self, from: r)
        #expect(result.ts.timeIntervalSince1970 == 60000.0)
    }
}

// MARK: - Date.timeIntervalSince1970 timezone independence

/// Verifies that `Date.timeIntervalSince1970` is UTC-based and not affected by
/// the device's local timezone.  `Date` is an absolute point in time; it has no
/// timezone property.  `timeIntervalSince1970` always measures seconds from
/// 1970-01-01T00:00:00Z regardless of the system timezone setting.
///
/// The test constructs dates from known UTC ISO 8601 strings and asserts that
/// `timeIntervalSince1970` equals the expected UTC seconds.  If the API were
/// timezone-sensitive the values would differ by the local UTC offset.
@Suite("Date.timeIntervalSince1970 – timezone independence")
struct DateEpochTimezoneTests {
    /// 1970-01-01T01:00:00Z is exactly 3600 seconds after the Unix epoch.
    /// No matter what timezone the device is in, the result must be 3600.
    @available(macOS 10.12, iOS 10.0, tvOS 10.0, watchOS 3.0, *)
    @Test("one hour after epoch is always 3600 seconds")
    func oneHourAfterEpoch() {
        let fmt = ISO8601DateFormatter()
        let date = fmt.date(from: "1970-01-01T01:00:00Z")!
        #expect(date.timeIntervalSince1970 == 3600.0)
    }

    /// 2001-01-01T00:00:00Z (Swift/Apple reference date) is exactly
    /// 978,307,200 seconds after the Unix epoch.  This is the value of
    /// `Date.timeIntervalBetween1970AndReferenceDate` and confirms the
    /// two epoch constants are consistent with UTC arithmetic.
    @available(macOS 10.12, iOS 10.0, tvOS 10.0, watchOS 3.0, *)
    @Test("reference date is 978307200 seconds after Unix epoch")
    func referenceDateOffset() {
        let fmt = ISO8601DateFormatter()
        let referenceDate = fmt.date(from: "2001-01-01T00:00:00Z")!
        #expect(referenceDate.timeIntervalSince1970 == 978_307_200.0)
        #expect(referenceDate.timeIntervalSince1970 == Date.timeIntervalBetween1970AndReferenceDate)
    }

    /// A date decoded from a stored value of 0 via `.secondsSince1970`
    /// must equal 1970-01-01T00:00:00Z, not the local midnight.
    @available(macOS 10.12, iOS 10.0, tvOS 10.0, watchOS 3.0, *)
    @Test("stored 0 decodes as Unix epoch, not local midnight")
    func storedZeroIsUnixEpoch() throws {
        struct W: Decodable { let ts: Date }
        var decoder = RowDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let r = row(("ts", .real(0)))
        let result = try decoder.decode(W.self, from: r)
        let fmt = ISO8601DateFormatter()
        #expect(fmt.string(from: result.ts) == "1970-01-01T00:00:00Z")
    }
}

// MARK: - Unit tests: CodingKeys mapping

@Suite("RowDecoder – CodingKeys mapping")
struct RowDecoderCodingKeysTests {

    struct MappedModel: Decodable {
        let userId: Int
        let fullName: String

        enum CodingKeys: String, CodingKey {
            case userId = "user_id"
            case fullName = "full_name"
        }
    }

    @Test("Maps snake_case column names to camelCase Swift properties")
    func codingKeysMapping() throws {
        let r = row(("user_id", .integer(7)), ("full_name", .text("Alice Smith")))
        let result = try RowDecoder().decode(MappedModel.self, from: r)
        #expect(result.userId == 7)
        #expect(result.fullName == "Alice Smith")
    }
}

// MARK: - Unit tests: error conditions

@Suite("RowDecoder – error conditions")
struct RowDecoderErrorTests {

    struct S: Decodable { let name: String }

    @Test("Type mismatch throws DecodingError.typeMismatch")
    func typeMismatch() throws {
        // name column holds an integer instead of text
        let r = row(("name", .integer(42)))
        #expect(throws: (any Error).self) {
            try RowDecoder().decode(S.self, from: r)
        }
    }

    @Test("NULL for non-optional column throws DecodingError")
    func nullForNonOptional() throws {
        struct Req: Decodable { let score: Double }
        let r = row(("score", .null))
        #expect(throws: (any Error).self) {
            try RowDecoder().decode(Req.self, from: r)
        }
    }

    @Test("Required column missing from row throws DecodingError.keyNotFound")
    func missingRequiredColumn() throws {
        // Row has no "name" column at all
        let r = row(("other", .integer(1)))
        #expect(throws: (any Error).self) {
            try RowDecoder().decode(S.self, from: r)
        }
    }
}

// MARK: - Unit tests: array decoding

@Suite("RowDecoder – array of rows")
struct RowDecoderArrayTests {

    struct Point: Decodable {
        let x: Int
        let y: Int
    }

    @Test("Decodes multiple rows into an array")
    func decodesArray() throws {
        let rows: [Row] = [
            row(("x", .integer(1)), ("y", .integer(2))),
            row(("x", .integer(3)), ("y", .integer(4))),
            row(("x", .integer(5)), ("y", .integer(6))),
        ]
        let result = try RowDecoder().decode(Point.self, from: rows)
        #expect(result.count == 3)
        #expect(result[0].x == 1 && result[0].y == 2)
        #expect(result[1].x == 3 && result[1].y == 4)
        #expect(result[2].x == 5 && result[2].y == 6)
    }

    @Test("Empty rows array yields empty array")
    func emptyRows() throws {
        let result = try RowDecoder().decode([Point].self, from: [])
        #expect(result.isEmpty)
    }
}

// MARK: - Integration tests: db.query(_, as:)

@Suite("RowDecoder – integration: typed db.query")
struct RowDecoderIntegrationTests {

    struct User: Decodable {
        let id: Int
        let name: String
        let email: String
        let score: Double?

        enum CodingKeys: String, CodingKey {
            case id, name, email, score
        }
    }

    @Test("db.query(sql, as:) returns decoded models")
    func rawSQLTypedQuery() async throws {
        let db = try makeDB()
        try await db.execute(
            CreateTable(TableName("users"))
                .column("id", .integer, .primaryKey)
                .column("name", .text, .notNull)
                .column("email", .text, .notNull)
                .column("score", .real))

        try await db.execute(
            "INSERT INTO users (id, name, email, score) VALUES (?, ?, ?, ?)",
            1, "Alice", "alice@example.com", 95.5)
        try await db.execute(
            "INSERT INTO users (id, name, email, score) VALUES (?, ?, ?, ?)",
            2, "Bob", "bob@example.com", 82.0)
        try await db.execute(
            "INSERT INTO users (id, name, email, score) VALUES (?, ?, ?, NULL)",
            3, "Carol", "carol@example.com")

        let users: [User] = try await db.query(
            "SELECT id, name, email, score FROM users ORDER BY id",
            as: User.self)

        #expect(users.count == 3)
        #expect(users[0].name == "Alice")
        #expect(users[0].score == 95.5)
        #expect(users[1].name == "Bob")
        #expect(users[2].name == "Carol")
        #expect(users[2].score == nil)
    }

    @Test("db.query(Select, as:) returns decoded models")
    func selectBuilderTypedQuery() async throws {
        let db = try makeDB()
        let tbl = TableName("items")
        try await db.execute(
            CreateTable(tbl)
                .column("id", .integer, .primaryKey)
                .column("label", .text, .notNull)
                .column("qty", .integer, .notNull))

        for (i, name) in ["Apple", "Banana", "Cherry"].enumerated() {
            try await db.execute(
                "INSERT INTO items (id, label, qty) VALUES (?, ?, ?)",
                i + 1, name, (i + 1) * 10)
        }

        struct Item: Decodable {
            let id: Int
            let label: String
            let qty: Int
        }

        let items: [Item] = try await db.query(
            Select(.all).from(tbl).orderBy(ColumnRef(tbl, "id")),
            as: Item.self)

        #expect(items.count == 3)
        #expect(items[0].label == "Apple")
        #expect(items[0].qty == 10)
        #expect(items[2].label == "Cherry")
    }

    @Test("db.query(BuiltQuery, as:) returns decoded models")
    func builtQueryTypedQuery() async throws {
        let db = try makeDB()
        let tbl = TableName("logs")
        try await db.execute(
            CreateTable(tbl)
                .column("id", .integer, .primaryKey)
                .column("msg", .text, .notNull))

        try await db.execute("INSERT INTO logs (id, msg) VALUES (1, 'first')")
        try await db.execute("INSERT INTO logs (id, msg) VALUES (2, 'second')")

        struct Log: Decodable {
            let id: Int
            let msg: String
        }

        let bq = Select(.all).from(tbl).build(params: [])
        let logs: [Log] = try await db.query(bq, as: Log.self)

        #expect(logs.count == 2)
        #expect(logs[0].msg == "first")
        #expect(logs[1].msg == "second")
    }

    @Test("db.query returns empty array when no rows match")
    func emptyResult() async throws {
        let db = try makeDB()
        try await db.execute(
            CreateTable(TableName("empty_tbl"))
                .column("id", .integer, .primaryKey))

        struct E: Decodable { let id: Int }
        let rows: [E] = try await db.query("SELECT id FROM empty_tbl", as: E.self)
        #expect(rows.isEmpty)
    }

    @Test("db.query with custom RowDecoder (iso8601 date)")
    func iso8601DateIntegration() async throws {
        let db = try makeDB()
        try await db.execute(
            CreateTable(TableName("events"))
                .column("id", .integer, .primaryKey)
                .column("name", .text, .notNull)
                .column("created_at", .text, .notNull))

        try await db.execute(
            "INSERT INTO events (id, name, created_at) VALUES (1, 'Launch', '2024-01-15T00:00:00Z')"
        )

        struct Event: Decodable {
            let id: Int
            let name: String
            let createdAt: Date
            enum CodingKeys: String, CodingKey {
                case id, name
                case createdAt = "created_at"
            }
        }

        var decoder = RowDecoder()
        if #available(macOS 10.12, iOS 10.0, tvOS 10.0, watchOS 3.0, *) {
            decoder.dateDecodingStrategy = .iso8601
        }

        let events: [Event] = try await db.query(
            "SELECT id, name, created_at FROM events",
            as: Event.self,
            decoder: decoder)

        #expect(events.count == 1)
        #expect(events[0].name == "Launch")
        // 2024-01-15T00:00:00Z → 1705276800
        #expect(abs(events[0].createdAt.timeIntervalSince1970 - 1_705_276_800) < 1.0)
    }
}
