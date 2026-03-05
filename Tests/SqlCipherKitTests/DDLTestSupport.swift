/// Test-only extensions that re-expose DDL builder execution on ``Database``
/// and ``Connection``.
///
/// In production code, DDL must go through the ``Migration`` system.
/// These overloads are intentionally absent from the library target and
/// exist here solely to keep integration and unit tests concise.
@testable import SqlCipherKit

extension Database {
    func execute(_ create: CreateTable) throws {
        try withConnection { try $0._execute(create.build()) }
    }

    func execute(_ alter: AlterTable) throws {
        try withConnection { try $0._execute(alter.build()) }
    }

    func execute(_ drop: DropTable) throws {
        try withConnection { try $0._execute(drop.build()) }
    }

    func execute(_ create: CreateIndex) throws {
        try withConnection { try $0._execute(create.build()) }
    }

    func execute(_ drop: DropIndex) throws {
        try withConnection { try $0._execute(drop.build()) }
    }
}

extension Connection {
    func execute(_ create: CreateTable) throws {
        try _execute(create.build())
    }

    func execute(_ alter: AlterTable) throws {
        try _execute(alter.build())
    }

    func execute(_ drop: DropTable) throws {
        try _execute(drop.build())
    }

    func execute(_ create: CreateIndex) throws {
        try _execute(create.build())
    }

    func execute(_ drop: DropIndex) throws {
        try _execute(drop.build())
    }
}
