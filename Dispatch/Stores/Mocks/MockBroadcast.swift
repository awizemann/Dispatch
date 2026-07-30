// MockBroadcast.swift
// Fan-out helper for the mock persistence actors: each subscriber gets the
// current value immediately, then every subsequent yield — mirroring GRDB
// ValueObservation's initial-emission-then-changes contract.
//
// Mock-grade on purpose: continuations are never removed (subscriber count is
// tiny and app-lifetime in the shell phase). Do not promote to production.

import Foundation

nonisolated struct MockBroadcast<Value: Sendable> {
    private var continuations: [AsyncThrowingStream<Value, Error>.Continuation] = []

    /// New stream that yields `initial` at once and stays subscribed for updates.
    mutating func subscribe(initial: Value) -> AsyncThrowingStream<Value, Error> {
        let (stream, continuation) = AsyncThrowingStream<Value, Error>.makeStream()
        continuation.yield(initial)
        continuations.append(continuation)
        return stream
    }

    /// Push a new value to every live subscriber.
    func yield(_ value: Value) {
        for continuation in continuations {
            continuation.yield(value)
        }
    }
}
