---
created: 2026-07-30
updated: 2026-07-30
source_sha: 4b184ef872b6a1d1473256df9ba78eddabb9b48a
source_paths: DispatchTests
source_paths_inferred: false
---

# Testing and Mocks

Dispatch uses Swift Testing (`@Suite`, `@Test`, `#expect`) — not XCTest. This page covers how to write tests, use mocks, and verify UI changes without spinning up real services.

## Running Tests

```bash
./scripts/build.sh
```

The build script runs the full test suite as part of its `build test` stage. Tests use an isolated DerivedData directory so they never collide with an Xcode GUI build.

To run tests from Xcode directly:
```
Cmd+U (scheme Dispatch, destination My Mac)
```

To run a single test:
```bash
swift test --filter BusRoutingTests
```

## Test Structure

**Test files:** `DispatchTests/*.swift`, organized by feature area:
- `AuditFixTests.swift` — database consistency audits and invariant checking
- `AuditFollowUpTests.swift` — icon decode isolation, refresh, discovery boundaries
- `DispatchBusTests.swift` — routing, round-trip delivery, wire protocol, expiry, long-poll seams
- `BusProtocolVersionTests.swift` — protocol version negotiation and compatibility
- `BusTextTests.swift` — text sanitization and framing rules
- `ProjectTests.swift` — project linking, unlinking, token rotation

**Structure:**

```swift
@Suite struct BusRoutingTests {
  @Test func askToUnlinkedProjectFails() async {
    // Arrange
    let (stores, _) = MockData.makeAppStores(withProjects: 2)
    // No link created between projects

    // Act & Assert
    let outcome = try await stores.router.ask(
      from: stores.projects[0].id,
      to: stores.projects[1].id,
      question: "..."
    )
    #expect(outcome.status == .refused(reason: .notLinked))
  }
}
```

Each test is self-contained with no setup/teardown boilerplate. Async/await is used throughout; no timing-dependent tests (no `sleep`, no expectations on event arrival times).

## Mocks and Fixtures

**Location:** `Dispatch/Stores/Mocks/`

### MockBroadcast

**Struct:** `MockBroadcast<Value: Sendable>` in `MockBroadcast.swift:11`

A Sendable broadcast sink for testing pub/sub-like behavior without `Notification.Name` or `@Observable` view updates. Useful for testing `ActivityStore` event broadcasting.

### MockData

**Enum:** `MockData` in `MockData.swift:18`

Factory methods for creating realistic test fixtures:
- `MockData.makeAppStores(withProjects: Int, linking: [(Int, Int)])` — creates an `AppStores` with mocked services and preconfigured project links
- `MockData.project(name:, at:)` — a single `ProjectRecord` fixture
- `MockData.busMessage(...)` — a single `BusMessageRecord` fixture

**Example:**
```swift
let (stores, router) = MockData.makeAppStores(
  withProjects: 3,
  linking: [(0, 1), (1, 2)]  // Project 0 → 1, Project 1 → 2
)
```

### MockBusArbitrator

**Class:** `MockBusArbitrator` in `MockData.swift:323`

A `BusArbitrating` implementation that doesn't require the real `MCPBusListener`. Useful for testing the router in isolation without HTTP I/O.

### MockGitStatus

**Actor:** `MockGitStatus` in `MockGitStatus.swift:8`

A `GitStatusProviding` implementation that returns fixed git status (all repos clean, all on main, 0 unpushed). Use when testing UI that depends on git status but you don't want to create real repos.

### MockGlobalPersistence

**Actor:** `MockGlobalPersistence` in `MockGlobalPersistence.swift:11`

An in-memory `GlobalPersistenceReading` implementation. All data is stored in memory; no I/O, no real database. Useful for testing stores and routers without the persistence layer.

## UI Verification

### Mock Scenario Launch

The app can launch with scripted fakes instead of real services:

```bash
open -n /Applications/Dispatch.app --args --mock-scenario
```

This launches Dispatch with:
- Mock git status (all repos show "clean main, 0 unpushed")
- Mock bus traffic (a few preconfigured questions/answers in the inbox)
- No I/O (all state is in-memory)
- The UI fully interactive for manual exploration

Useful for verifying layout, state transitions, and responsiveness without needing real repos or a running Claude Code session.

### UI Testing Boundary

Per [[memophant/conventions/ui-verification-policy]], **never** drive the real user session or the system in automated UI tests:
- No global HID event synthesis (no moving the mouse)
- No child process spawning
- No focusing or foregrounding other apps
- No reaching into the system outside the app's own window

Only verify the app's own UI in isolation. When a UI change affects the session (e.g., a new MCP tool), test the tool logic with unit tests, then verify the UI manually with `--mock-scenario`.

## Coverage

**Integration tests:**
- Bus routing (ask/answer flow, linkage checking, delivery modes)
- Message round-trip (ask → answer → outcome inbox)
- Expiry and cleanup
- Long-poll timeouts and early answers
- Protocol version negotiation

**Unit tests:**
- Text sanitization and framing
- Git porcelain v2 output parsing
- Database schema and migrations
- Project identity and link invariants

**Audit tests:**
- No orphaned messages (every message has a valid sender and receiver)
- No stale links (both sides of a link exist)
- No duplicate outcomes
- Bus token uniqueness

All tests are deterministic and non-timing-dependent.

---

_Last updated: 2026-07-30 — new_