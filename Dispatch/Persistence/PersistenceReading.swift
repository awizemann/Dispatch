// PersistenceReading.swift
// Protocol seams for the READ/OBSERVE surface of the persistence actors — the only
// dependency stores should take for reads, so test fakes can drive them with scripted
// data. Writes go through the concrete actors until a second implementation exists
// (approved scope decision, 2026-07-05).
//
// Both protocols are `nonisolated protocol ...: Actor` — required so actor fakes can
// conform under SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor (see
// .memory/conventions/testing-standards).

import Foundation
import GRDB
import os

private nonisolated let readLogger = Logger(subsystem: "com.wizemann.dispatch", category: "persistence")

// MARK: - Global database (Dispatch's only database)

nonisolated protocol GlobalPersistenceReading: Actor {
    func fetchProjects() async throws -> [Project]

    /// Cross-project links: the global `projectLink` rows, ordered by
    /// createdAt. Lifted onto the read seam here so the project-settings links
    /// section (and its mock-scenario render) can be driven with injectable
    /// link data.
    func fetchProjectLinks() async throws -> [ProjectLink]

    /// Every cross-project question/answer row, newest first (Dispatch P3). The
    /// bus message table is GLOBAL now — a message belongs to a PAIR of
    /// projects, never to one — so the Messages inbox reads it through this
    /// seam instead of a per-project source.
    func fetchBusMessages() async throws -> [BusMessage]

    func observeProjects() -> AsyncThrowingStream<[Project], Error>
    func observeProjectLinks() -> AsyncThrowingStream<[ProjectLink], Error>
    func observeBusMessages() -> AsyncThrowingStream<[BusMessage], Error>
}

// MARK: - Logged reads (Std 02 §5)

/// Runs a throwing async persistence READ; on failure logs the error (category
/// "persistence") tagged with `operation` and returns `fallback`. Replaces bare
/// `(try? await …) ?? default` so a genuine DB error is traced instead of
/// silently degrading to an empty/absent result. Control flow is unchanged: the
/// caller still gets exactly `fallback` on error. `#isolation` makes the read
/// closure run in the caller's isolation, so no Sendable hop is introduced.
func safeRead<T>(
    _ operation: String,
    fallback: T,
    isolation: isolated (any Actor)? = #isolation,
    _ read: () async throws -> T
) async -> T {
    do {
        return try await read()
    } catch {
        readLogger.error("read failed [\(operation, privacy: .public)]: \(error)")
        return fallback
    }
}

/// Optional-returning variant for `guard let`/`if let`/`?.first` sites: logs and
/// returns nil on failure, preserving the exact "error ⇒ nil ⇒ skip" flow of a
/// bare `try?` that fed an optional binding.
func safeRead<T>(
    _ operation: String,
    isolation: isolated (any Actor)? = #isolation,
    _ read: () async throws -> T
) async -> T? {
    do {
        return try await read()
    } catch {
        readLogger.error("read failed [\(operation, privacy: .public)]: \(error)")
        return nil
    }
}

// MARK: - Shared observation plumbing

/// Bridges a GRDB ValueObservation into an AsyncThrowingStream of Sendable values.
/// The observation's tracked fetch runs off-main inside GRDB; only Sendable values
/// cross into the stream (record → DTO mapping happens inside the tracked closure).
nonisolated func observationStream<Value: Sendable>(
    _ observation: ValueObservation<ValueReducers.Fetch<Value>>,
    in reader: some DatabaseReader & Sendable
) -> AsyncThrowingStream<Value, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                for try await value in observation.values(in: reader) {
                    continuation.yield(value)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}
