---
title: Memophant Server Health Interpretation
type: note
permalink: dispatch/operations/memophant-server-health-interpretation
tags: [operations, memophant, mcp]
grounding: durable
created: 2026-07-05
updated: 2026-07-30
---

## Observations
- [convention] IGNORE memophant-mcp 'stale binary / rebuilt since session start' warnings — Alan actively develops Memophant alongside this project and rebuilds are routine #warnings
- [convention] The only memophant signal that matters: if the server's tool count drops to just 1 tool, that's license protection engaging — surface it to Alan immediately; at 27 tools everything is healthy regardless of build-staleness warnings #health
- [fact] Memophant is Alan's own app and is vital to this repo's memory and process infrastructure — treat its availability as load-bearing, not optional tooling #context
