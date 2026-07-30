// PersistenceTestSupport.swift
// Shared helpers + fixtures for the persistence suites.

import Foundation
@testable import DispatchApp

/// Thread-safe box for collecting values from observation streams in tests.
nonisolated final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value { lock.withLock { storage } }

    func mutate(_ body: (inout Value) -> Void) {
        lock.withLock { body(&storage) }
    }
}

/// Polls a condition with early exit (20 × 100ms) — testing-standards rule: never
/// sleep-then-assert. Returns true as soon as the condition holds.
func pollUntil(_ condition: () -> Bool) async throws -> Bool {
    for _ in 0..<20 {
        if condition() { return true }
        try await Task.sleep(for: .milliseconds(100))
    }
    return condition()
}

// MARK: - Fixtures

enum Fixtures {
    /// GRDB stores dates at millisecond precision ("YYYY-MM-DD HH:MM:SS.SSS"), so
    /// round-trip equality requires fixture dates without sub-millisecond noise.
    static func date(offset: TimeInterval = 0) -> Date {
        Date(timeIntervalSince1970: 1_750_000_000 + offset)
    }

}
