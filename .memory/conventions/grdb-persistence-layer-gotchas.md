---
title: GRDB Persistence Layer Gotchas
type: note
permalink: dispatch/conventions/grdb-persistence-layer-gotchas
tags: [grdb, persistence, gotcha, concurrency]
source_paths: [Dispatch/Persistence, DispatchTests/PersistenceRoundTripTests.swift]
source_paths_inferred: false
source_sha: 5806824c6bf9f806d26d1aefcd714792d65891fa
created: 2026-07-05
updated: 2026-07-30
reviewed: 2026-07-26
reviewed_by: audit:claude-code (background)
---

Learned while building the persistence foundation (now `Dispatch/Persistence/`, 2026-07-05). The debounce self-cancel bug was caught by the discriminating auto-flush test — it silently swallowed every timer-driven flush before the fix.

## Observations
- [gotcha] GRDB async reads/writes honor Task cancellation — a debounce/flush routine must NEVER cancel the Task it is currently running on (timer task clears its own handle BEFORE flushing; only external flushes cancel the timer) #concurrency
- [gotcha] Under SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor, actor STATIC members and nested types default to MainActor — mark them `nonisolated` explicitly or pool opens run on main and DB-queue closures can't call them #isolation
- [gotcha] GRDB stores Date at millisecond precision ("YYYY-MM-DD HH:MM:SS.SSS") — round-trip equality tests need fixture dates without sub-ms noise (Fixtures.date uses whole-second epochs) #testing
- [convention] Structs with autoincremented ids conform to MutablePersistableRecord (mutating didInsert), not PersistableRecord — the non-mutating default silently wins otherwise and rowids are never captured #records
- [convention] Migration locked-list tests compare the ORDERED DatabaseMigrator.migrations array, not the appliedIdentifiers Set — a Set cannot detect reordering #migrations

## Relations
- relates_to [[Decision: Persistence via GRDB]]
- relates_to [[Sendable DTO Boundary Architecture]]



## Record-only columns + narrow read seams (2026-07-08)

Some columns exist ONLY at the record layer by design — e.g. BusMessageRecord.createdAt is persisted but deliberately dropped from the domain BusMessage DTO (approved ruling: message ordering rides the monotonic MSG-id counter, views never see wall-clock). When an internal consumer legitimately needs such a column (the stale-question monitor needs age), do NOT add it to the domain DTO — expose a narrow, consumer-named read seam instead (OpenBusQuestion = (BusMessage, createdAt) pair via fetchOpenBusQuestions on ProjectPersistenceReading). The domain surface stays clean, the views can't grow a dependency on it, and the seam documents exactly who consumes the column and why. Check the record layer for an existing column BEFORE adding migrations or in-memory stamping — BusMessageRecord already had what the monitor needed.


- [gotcha] PARALLEL BRANCHES MINTING THE SAME MIGRATION NUMBER: two branches each added a "v011" global migration under different identifiers and merged 2026-07-23. Resolution: KEEP both identifiers unchanged and register both sequentially — GRDB tracks applied migrations by identifier string, so renaming one to "v012" re-runs it on any dev database that already applied it under the old name (duplicate-column crash). The vNNN prefix is cosmetic; the identifier is the contract. PersistenceMigrationTests' expected-list carries both v011 entries with a merge note. When branching schema work in parallel, expect this and resolve by union-in-registration-order, never by rename #migration #merge
