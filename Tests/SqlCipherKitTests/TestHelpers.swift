import Foundation
import Testing

@testable import SqlCipherKit

// MARK: - Shared test helpers

func tempDBPath() -> String {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sqlcipherkit-test-\(UUID().uuidString).db")
        .path
}
