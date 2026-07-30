---
title: Dispatch product pivot — switchboard rebuild 2026-07-28
type: note
permalink: dispatch/project/dispatch-product-pivot-switchboard-rebuild-2026-07-28
tags: [dispatch, pivot, bus]
source_paths: [Dispatch/Services/MCPBus, Dispatch/Stores/AppStores.swift]
source_paths_inferred: false
source_sha: e24495a2b7b67f6aed88344545a31286318bdd6b
created: 2026-07-29
updated: 2026-07-30
reviewed: 2026-07-30
reviewed_by: human
---
## Observations
- [fact] This repo is Dispatch, a macOS switchboard: link local repos, install a "dispatch" http entry into each repo's .mcp.json, and external Claude Code sessions ask each other questions over the bus #product
- [fact] The bus exposes exactly four MCP tools — ask_agent (sync-when-live long-poll via wait_seconds), answer_agent, check_messages, list_projects — auth is a durable per-project 128-bit token routed by MCPBusListener #bus
- [decision] Dispatch never spawns agents; identity is one endpoint per project; a human-created projectLink is the consent boundary (asks fail closed without it) #design
- [fact] Dispatch went through a major internal rewrite that shrank the app considerably while landing the current bus-first design; plan and audit live in documents/plans/dispatch-rebuild-plan-2026-07-28.md and documents/reports/dispatch-slimdown-audit-2026-07-28.md #history
