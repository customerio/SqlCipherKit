import Foundation
import Testing

@testable import SqlCipherKit

// MARK: - Fixtures

private struct Account: Entity, Equatable {
    static let tableName = TableName("accounts")
    static let primaryKey = \Account.id
    var id: Int?
    var owner: String
    var balance: Double
}

private struct Entry: Entity, Equatable {
    static let tableName = TableName("entries")
    static let primaryKey = \Entry.id
    var id: Int?
    var accountID: Int
    var amount: Double
}

private struct Boom: Error {}

private func makeDB() async throws -> Database {
    let db = try Database(path: tempDBPath(), key: "k")
    try await db.execute(
        "CREATE TABLE accounts (id INTEGER PRIMARY KEY, owner TEXT NOT NULL UNIQUE, balance REAL NOT NULL)"
    )
    try await db.execute(
        "CREATE TABLE entries (id INTEGER PRIMARY KEY, accountID INTEGER NOT NULL, amount REAL NOT NULL)"
    )
    return db
}

// MARK: - Transactions

@Suite("Entities inside transactions")
struct EntityTransactionTests {

    @Test("Commits entity saves and raw SQL together and returns the body's value")
    func commits() async throws {
        let db = try await makeDB()
        let account = try await db.transaction { conn in
            let account = try conn.save(Account(id: nil, owner: "alice", balance: 0))
            try conn.save([
                Entry(id: nil, accountID: account.id!, amount: 10),
                Entry(id: nil, accountID: account.id!, amount: 5),
            ])
            try conn.execute("UPDATE accounts SET balance = ? WHERE id = ?", 15.0, account.id!)
            return account
        }
        #expect(account.id == 1)
        let actual1 = try await db.fetchOne(Account.self, id: 1)?.balance
        #expect(actual1 == 15)
        let actual2 = try await db.fetch(Entry.self).count
        #expect(actual2 == 2)
    }

    @Test("Reads inside the body see its uncommitted writes")
    func readsOwnWrites() async throws {
        let db = try await makeDB()
        let seen = try await db.transaction { conn in
            try conn.save(Account(id: nil, owner: "bob", balance: 1))
            return try conn.fetch(Account.self, where: col("owner") == "bob").count
        }
        #expect(seen == 1)
    }

    @Test("Rolls back every entity operation when the body throws")
    func rollsBack() async throws {
        let db = try await makeDB()
        try await db.save(Account(id: 1, owner: "keep", balance: 1))
        await #expect(throws: Boom.self) {
            try await db.transaction { conn in
                try conn.save(Account(id: nil, owner: "carol", balance: 1))
                try conn.save([Entry(id: nil, accountID: 1, amount: 1)])
                try conn.delete(Account.self, id: 1)
                throw Boom()
            }
        }
        let actual3 = try await db.fetch(Account.self)
        #expect(actual3 == [Account(id: 1, owner: "keep", balance: 1)])
        let remaining1 = try await db.fetch(Entry.self)
        #expect(remaining1.isEmpty)
    }

    @Test("A batch save inside a transaction does not commit on its own")
    func batchSaveNests() async throws {
        let db = try await makeDB()
        await #expect(throws: Boom.self) {
            try await db.transaction { conn in
                try conn.save([
                    Account(id: nil, owner: "a", balance: 0),
                    Account(id: nil, owner: "b", balance: 0),
                ])
                throw Boom()
            }
        }
        let remaining2 = try await db.fetch(Account.self)
        #expect(remaining2.isEmpty)
    }

    @Test("A failed batch rolls back only itself; the transaction continues")
    func failedBatchIsContained() async throws {
        let db = try await makeDB()
        try await db.transaction { conn in
            try conn.save(Account(id: nil, owner: "first", balance: 0))
            #expect(throws: SqlCipherError.self) {
                try conn.save([
                    Account(id: nil, owner: "second", balance: 0),
                    Account(id: nil, owner: "first", balance: 0),  // UNIQUE violation
                ])
            }
            try conn.save(Account(id: nil, owner: "third", balance: 0))
        }
        let owners = try await db.fetch(Account.self).map(\.owner).sorted()
        #expect(owners == ["first", "third"])
    }

    @Test("A savepoint can be undone without abandoning the transaction")
    func savepointPartialRollback() async throws {
        let db = try await makeDB()
        try await db.transaction { conn in
            try conn.save(Account(id: nil, owner: "kept", balance: 0))
            #expect(throws: Boom.self) {
                try conn.savepoint { sp in
                    try sp.save(Account(id: nil, owner: "undone", balance: 0))
                    throw Boom()
                }
            }
        }
        let actual4 = try await db.fetch(Account.self).map(\.owner)
        #expect(actual4 == ["kept"])
    }

    @Test("A batch save outside a transaction is still atomic")
    func batchSaveAtomicOutsideTransaction() async throws {
        let db = try await makeDB()
        await #expect(throws: SqlCipherError.self) {
            try await db.save([
                Account(id: nil, owner: "x", balance: 0),
                Account(id: nil, owner: "x", balance: 0),
            ])
        }
        let remaining3 = try await db.fetch(Account.self)
        #expect(remaining3.isEmpty)
        // The connection is usable afterwards (no transaction left open).
        try await db.save([Account(id: nil, owner: "y", balance: 0)])
        let actual5 = try await db.fetch(Account.self).count
        #expect(actual5 == 1)
    }
}

// MARK: - Delete

@Suite("Entity delete")
struct EntityDeleteTests {

    @Test("Deletes by primary key and reports the count")
    func deleteByID() async throws {
        let db = try await makeDB()
        try await db.save([
            Account(id: nil, owner: "a", balance: 0), Account(id: nil, owner: "b", balance: 0),
        ])
        let actual6 = try await db.delete(Account.self, id: 1)
        #expect(actual6 == 1)
        let actual7 = try await db.delete(Account.self, id: 1)
        #expect(actual7 == 0)
        let actual8 = try await db.fetch(Account.self).map(\.owner)
        #expect(actual8 == ["b"])
    }

    @Test("Deletes rows matching a predicate, with params")
    func deleteWhere() async throws {
        let db = try await makeDB()
        try await db.save([
            Entry(id: nil, accountID: 1, amount: 1),
            Entry(id: nil, accountID: 1, amount: 50),
            Entry(id: nil, accountID: 2, amount: 2),
        ])
        let limit = Param<Double>("limit")
        let removed = try await db.delete(Entry.self, where: col("amount") < limit, limit.set(10))
        #expect(removed == 2)
        let actual9 = try await db.fetch(Entry.self).map(\.amount)
        #expect(actual9 == [50])
    }
}
