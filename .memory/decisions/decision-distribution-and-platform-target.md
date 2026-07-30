---
title: Decision: Distribution and Platform Target
type: note
permalink: dispatch/decisions/decision-distribution-and-platform-target
created: 2026-07-05
updated: 2026-07-05
tags:
- decision
- distribution
- platform
---

**Why:** Dispatch hosts a localhost MCP bus server, holds security-scoped access to arbitrary user repos and writes into their `.mcp.json` — hostile to the App Store sandbox; every comparable product (Conductor, GitKraken, Fork, Tower direct) ships Developer ID non-sandboxed. Chosen by Alan 2026-07-05.

## Observations
- [decision] Ship non-sandboxed: Developer ID + notarized + hardened runtime; App Store is permanently off the table (agent child processes need arbitrary exec/network) #distribution
- [decision] Minimum macOS 26 (Tahoe) only — latest SwiftUI, no availability guards; dev-tool audience updates fast #target
- [decision] Commercial from the start: every dependency must be MIT/Apache/BSD — vet licenses before adopting; AGPL (e.g. opcode) is study-only; Sparkle for updates + Paddle for sales planned as a late phase #commercial
- [convention] Still use security-scoped-bookmark-style folder pickers as UX for repo selection, just not as sandbox enforcement #ux
