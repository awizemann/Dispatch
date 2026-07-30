---
title: Sendable DTO Boundary Architecture
type: note
permalink: dispatch/architecture/sendable-dto-boundary-architecture
tags: [architecture, swiftui, standard]
source_paths: [Dispatch/Stores/AppStores.swift, Dispatch/Models/DomainModels.swift, Dispatch/Persistence]
source_paths_inferred: false
source_sha: e24495a2b7b67f6aed88344545a31286318bdd6b
created: 2026-07-05
updated: 2026-07-30
reviewed: 2026-07-30
reviewed_by: human
---

Portable architecture principle from the kickoff standard (§3), mapped to Dispatch: domain stores (projects, bus/messages, settings) are @Observable @MainActor; the MCP bus client and git service are actors behind `nonisolated protocol`s (see [[Swift 6.2 Concurrency Rules]]). Shipped: GitClient is an actor behind the `GitStatusProviding` protocol — the kickoff-era `Models.swift` sketch that declared `MCPBusClient`/`GitService` as Actor protocols has been superseded by the concrete service actors.

## Observations
- [convention] SwiftUI views and @Observable stores consume ONLY Sendable value DTOs — no persistence model ever crosses into a view, no @Query in views #boundary
- [fact] WHY: reading a faulted persistence-model relationship from a view body can crash uncatchably mid-layout; a DTO-only view layer makes that crash class structurally impossible #rationale
- [convention] One @Observable @MainActor store per domain owns UI state and reloads only on real change, never speculatively #stores
- [convention] Exactly one persistence actor is the only place DB models are touched; it maps model → DTO off-main and owns all queries/predicates #persistence
- [convention] Views and stores depend on Sendable repository/service protocols, never concrete stores — which is what lets `--mock-scenario` swap the whole persistence + bus layer for actor fakes with no view change #protocolssame interfaces #protocols

## Relations
- relates_to [[Swift 6.2 Concurrency Rules]]
