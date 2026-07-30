---
title: Swift 6.2 Concurrency Rules
type: note
permalink: dispatch/conventions/swift-6-2-concurrency-rules
tags: [swift6, concurrency, standard]
created: 2026-07-05
updated: 2026-07-30
---

Distilled from the proven engineering standard in documents/Swift 6.2 Mac OS Kick Off Prompt.md §2 — every rule traces to a real defect. Dispatch consequence: the bus listener/router seams, the repo `.mcp.json` installer, and the git client are actors; any protocol they conform to must be declared `nonisolated protocol`, and any shared helper they call synchronously must be `nonisolated`. Non-Sendable platform types run on their required actor; sanctioned `nonisolated(unsafe)` bridging for a framework's single-threaded callback is acceptable but must be documented here so a later audit doesn't "fix" it.

## Observations
- [convention] Build with SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor — every unannotated top-level declaration is implicitly @MainActor; helpers/protocols an actor must use synchronously must be explicitly `nonisolated` #isolation
- [gotcha] `async` on a @MainActor type does NOT leave the main thread — the body runs on main until the first real suspension; wrap blocking work in Task.detached(priority:.userInitiated) with explicit @Sendable capture #performance
- [convention] os.Logger declared at file scope as `private nonisolated let logger = Logger(subsystem:category:)` — plain `private let` becomes MainActor-isolated and unusable from actors #logging
- [gotcha] @Observable class with a nonisolated(unsafe) var lock/flag: Xcode's 'has no effect' warning is a FALSE POSITIVE — fix is @ObservationIgnored + keep nonisolated(unsafe); never observation-track concurrency primitives #observable
- [convention] Notification.Name constants are `nonisolated static let`; use os_unfair_lock (not NSLock) for thread-safe flags; all Task/Task.detached/continuation closures are @Sendable #isolation


**Field-proven additions (P0, 2026-07-05):** (1) actor STATIC members and nested types also default to MainActor — mark `nonisolated` explicitly or pool-opens run on main and DB-queue closures can't call them; (2) structs conforming to SwiftUI `Layout` must be declared `nonisolated struct` (same family — the conformance is nonisolated); (3) GRDB async reads/writes honor Task cancellation — never cancel the Task a flush is currently running on (see [[GRDB Persistence Layer Gotchas]]).
