---
title: Performance and Cold Start Rules
type: note
permalink: dispatch/conventions/performance-and-cold-start-rules
created: 2026-07-05
updated: 2026-07-05
tags:
- performance
- standard
---

From kickoff standard §5 — the dominant defect class is blocking work on the main actor. Dispatch-specific hot spots to watch: git status scans on repo selection and refresh, bus long-polls (ask_agent's wait_seconds must never occupy the main actor), and inbox observation churn as messages land. Wrap render/decode loops in Task.detached + per-iteration autoreleasepool (no await inside the pool).

## Observations
- [convention] No synchronous file/image I/O on @MainActor — never NSImage(contentsOf:), Data(contentsOf:), sync FileManager/NSFileCoordinator inside a View body or any @MainActor method; use .task(id:)/async wrappers #mainthread
- [convention] Boot must not block main: open the persistence container OFF the synchronous App init via Task.detached, show a lightweight launch placeholder, then wire dependencies on main #coldstart
- [convention] Never fake a wait — no Task.sleep as a stand-in for a real signal, no busy-poll; await a CheckedContinuation/AsyncStream/notification resumed at the real milestone #signals
- [convention] No `Date()` perf timing in hot paths (interpolation is eager even in Release) — gate behind #if DEBUG or use os_signpost #timing
- [convention] Any background pass occupying a serial actor >~0.8s must drive a visible background-activity indicator, or the UI reads as frozen #feedback
