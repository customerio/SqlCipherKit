import Foundation
import Testing

@testable import SqlCipherKit

@Suite("SQLConvertible Conformances")
struct ValueConformanceTests {

    @Test("Bool round-trips")
    func boolRoundTrip() async throws {
        let db = try Database(path: tempDBPath(), key: "k")
        try await db.execute("CREATE TABLE flags (active INTEGER)")
        try await db.execute("INSERT INTO flags VALUES (?)", true)
        let v = try await db.scalarQuery("SELECT active FROM flags", as: Bool.self)
        #expect(v == true)
    }

    @Test("Data round-trips")
    func dataRoundTrip() async throws {
        let db = try Database(path: tempDBPath(), key: "k")
        try await db.execute("CREATE TABLE blobs (raw BLOB)")
        let original = Data([0xDE, 0xAD, 0xBE, 0xEF])
        try await db.execute("INSERT INTO blobs VALUES (?)", original)
        let result = try await db.scalarQuery("SELECT raw FROM blobs", as: Data.self)
        #expect(result == original)
    }
}
