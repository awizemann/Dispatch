---
title: GRDB Persistence Layer Gotchas
type: note
permalink: dispatch/conventions/grdb-persistence-layer-gotchas
tags: [grdb, persistence, gotcha, concurrency]
source_paths: [Dispatch/Persistence, DispatchTests/PersistenceRoundTripTests.swift]
source_paths_inferred: false
source_sha: e24495a2b7b67f6aed88344545a31286318bdd6b
created: 2026-07-05
updated: 2026-07-30
reviewed: 2026-07-30
reviewed_by: human
---

## Observations
- [gotcha] GRDB async reads/writes honor Task cancellation — a debounce/flush routine must NEVER cancel the Task it is currently running on (timer task clears its own handle BEFORE flushing; only external flushes cancel the timer) #concurrency
- [gotcha] Under SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor, actor STATIC members and nested types default to MainActor — mark them `nonisolated` explicitly or pool opens run on main and DB-queue closures can't call them #isolation
- [gotcha] GRDB stores Date at millisecond precision ("YYYY-MM-DD HH:MM:SS.SSS") — round-trip equality tests need fixture dates without sub-ms noise (Fixtures.date uses whole-second epochs) #testing
- [convention] Structs with autoincremented ids conform to MutablePersistableRecord (mutating didInsert), not PersistableRecord — the non-mutating default silently wins otherwise and rowids are never captured #records
- [convention] Migration locked-list tests compare the ORDERED DatabaseMigrator.migrations array, not the appliedIdentifiers Set — a Set cannot detect reordering #migrations

## Relations
- relates_to [[Decision: Persistence via GRDB]]
- relates_to [[Sendable DTO Boundary Architecture]]
