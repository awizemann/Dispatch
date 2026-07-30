---
title: Dispatch Project Overview
type: note
permalink: dispatch/project/dispatch-project-overview
tags: [project, overview]
created: 2026-07-05
updated: 2026-07-30
---
## Observations
- [fact] Dispatch is a native macOS app (Swift 6.2 / SwiftUI, macOS 26+) that acts as a SWITCHBOARD between local repos: the human links repos as projects, Dispatch merges a `dispatch` http entry into each repo's `.mcp.json`, and the external Claude Code sessions running in those repos ask each other questions over the bus #product
- [fact] Owner: Alan Wizemann; repo Dispatch #project
- [fact] The whole agent-facing surface is four MCP tools — `ask_agent` (long-poll inline answer via `wait_seconds`, else pending), `answer_agent`, `check_messages`, `list_projects` — served by DispatchEndpoint over one in-process localhost HTTP MCP server (MCPBusListener, `http://127.0.0.1:<port>/bus/<token>`) #bus
- [constraint] Core invariants: Dispatch NEVER spawns agents and never edits repos beyond the `.mcp.json` key it owns; identity is one durable 128-bit token per project (structural, unspoofable); a human-created projectLink is the consent boundary and asks fail closed without it; questions are questions, never remote task injection #invariants
- [fact] Persistence is GRDB/SQLite (one global DB + per-project DBs); the UI is projects rail + message center + settings, verified headlessly through `--mock-scenario` #architecture

## Relations
- relates_to [[Dispatch product pivot — switchboard rebuild 2026-07-28]]
- relates_to [[Design System and Accessibility Rules]]
- relates_to [[Sendable DTO Boundary Architecture]]
- relates_to [[Decision: MCP Bus via Official Swift SDK]]
