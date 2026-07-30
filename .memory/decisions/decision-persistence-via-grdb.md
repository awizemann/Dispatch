---
title: Decision: Persistence via GRDB
type: note
permalink: dispatch/decisions/decision-persistence-via-grdb
tags: [decision, persistence, grdb]
created: 2026-07-05
updated: 2026-07-29
---
Follows kickoff standard §4: the store's role is decided explicitly — system of record for bus state, rebuildable cache for anything derivable from the repo. ONE canonical model list, ONE construction site per database; tests build from the same list. Decided 2026-07-05; re-confirmed for Dispatch 2026-07-29 (the chat/transcript half of the original ruling died with the pivot).

## Observations
- [decision] Persistence = GRDB 7 (SQLite, WAL, DatabasePool), NOT SwiftData — one database per project under Application Support, plus a small global store (settings, projects, project links) #persistence
- [decision] The database IS the system of record for bus state (questions, answers, delivery/redelivery bookkeeping, project links, per-project tokens) → we owe real schema migrations (GRDB DatabaseMigrator) from day one and never nuke #systemofrecord
- [convention] Reads go through the logged `safeRead` helpers in PersistenceReading.swift — never a bare `try?` on a database read or write #reads
- [fact] WHY GRDB over SwiftData: Swift 6-native (GRDB 7), ValueObservation for reactive UI, FTS5, predictable write performance; SwiftData had a destabilizing rewrite and no FTS #rationale

## Relations
- relates_to [[Sendable DTO Boundary Architecture]]
- relates_to [[GRDB Persistence Layer Gotchas]]
