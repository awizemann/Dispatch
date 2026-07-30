---
title: Testing Standards
type: note
permalink: dispatch/conventions/testing-standards
tags: [testing, standard]
created: 2026-07-05
updated: 2026-07-29
---

From kickoff standard §9. Dispatch's highest-value test seams: the four bus verbs end to end through DispatchEndpoint/DispatchRouter, the `.mcp.json` merge/uninstall/conflict matrix (RepoMCPInstaller), the injection-framing property tests, token routing and link fail-closed refusal, and the persistence round trips.

## Observations
- [convention] Swift Testing (@Suite/@Test), not XCTest; protocol-oriented mocks via dependency injection #framework
- [gotcha] Protocols an actor fake conforms to must be `nonisolated protocol` — bites hardest in test fakes like `private actor FakeBusClient: MCPBusClient` #isolation
- [convention] No timing-dependent tests — poll with early exit (20 × 100ms), never sleep-then-assert; singleton isolation via cleanup + await Task.yield() before assertions #flakiness
- [convention] Tests must be discriminating, not checkboxes — a real test fails on the broken code and passes on the fix; state in the test/commit how you know it discriminates #quality
- [gotcha] App-hosted suites run in Debug (need ENABLE_TESTABILITY; Release breaks @testable import) #build


- [gotcha] Historical flake note (pre-pivot, kept for the pattern): two Memophant capability-probe tests were flaky-RED under the full parallel run and green in isolation — an mtime-timing flake, NOT the MainActor wall-clock-starvation family. The general rule survives the suites that produced it: before attributing a full-suite red to the diff under review, isolate-rerun the failures AND confirm from the log that they actually executed #testing
