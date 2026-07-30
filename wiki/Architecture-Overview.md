---
source_sha: 4738c8d1f4cb39ace4c5dd75abca831026d7cb9e
source_paths: Dispatch/Services, Dispatch/Stores, Dispatch/Views, Dispatch/Persistence
source_paths_inferred: false
created: 2026-07-12
updated: 2026-07-30
---

# Architecture Overview

Dispatch's architecture flows from one principle: **the agents are somebody else's processes**. Dispatch never spawns them, never sees their transcripts, and holds no credential of theirs. It hosts one localhost MCP server, gives each linked project an identity on it, and routes questions between the projects a human has linked. See [Technical Specification](technical-specification) for layer detail, and [How Dispatch Works](How-Dispatch-Works) for a narrative walkthrough of the bus itself.

## Conceptual model

```
┌────────────────────────────────────────────────────────────┐
│  SwiftUI Views (design system)                             │
│  ↓ (Sendable DTOs only — no DB types)                      │
│  @Observable @MainActor Stores                             │
│  • AppStores → ProjectStore, MessageStore,                 │
│    ActivityStore, CrossProjectStore                        │
│  ↓ (protocol seams: PersistenceReading, GitStatusProviding,│
│     BusArbitrating, SoundPlaying)                          │
│  Actors & Services                                         │
│  ├─ MCPBusListener  (SwiftNIO, 127.0.0.1:<kernel port>)    │
│  ├─ DispatchEndpoint (one MCP Server per project identity) │
│  ├─ DispatchRouter   (ask/answer/inbox/expiry — the brain) │
│  ├─ RepoMCPInstaller (owns the repo's "dispatch" key)      │
│  ├─ GitClient        (shells to the git executable)        │
│  └─ GlobalDatabase / project DBs (GRDB actors)             │
│  ↓                                                          │
│  Outside the app                                            │
│  ├─ YOUR claude sessions, one per repo, started by you     │
│  ├─ each repo's .mcp.json (one key: "dispatch")            │
│  └─ ~/Library/Application Support/Dispatch/*.sqlite        │
└────────────────────────────────────────────────────────────┘
```

Note what is absent: no subprocess runtime, no worktrees, no chat transcript engine, no commit gate, no QA pipeline, no accounts.

## The bus

See [How Dispatch Works](How-Dispatch-Works) for the full walkthrough; the summary:

- **Listener** (`Dispatch/Services/MCPBus/MCPBusListener.swift`) — one SwiftNIO HTTP server for the whole app, bound to `127.0.0.1` on a kernel-assigned port (it re-binds the persisted port on later launches, because every `.mcp.json` on disk already points at it). It routes `POST /bus/<token>` to a project. The token *is* the route; there is no header to trust and no identity to assert.
- **Endpoint** (`DispatchEndpoint.swift`) — one MCP `Server` per project, serving the four tools, with handlers closed over that project's fixed identity. Project A physically cannot reach B's endpoint.
- **Router** (`DispatchRouter.swift`) — the brain: ask, answer, inbox assembly, long-poll waiters, redelivery, expiry, exactly-once outcome reporting, and the fail-closed link check.
- **Framing** (`BusProtocolText.swift`, `BusEventText.swift`, `BusTextSanitizer`) — every value from another repo is folded before it lands on a framing line, and bodies ride inside fences as DATA, never instructions.

### Identity and auth

One durable 128-bit token per project, minted at link time, stored in the global DB (`projectBusToken`) and embedded in the URL Dispatch writes into that repo's `.mcp.json`. Identity is **structural**: whoever can reach the route is that project, and nothing else can be spoofed. Rotation revokes the listener route and rewrites the entry.

### Consent

A `projectLink` row — created by the human, never by an agent — is the only thing that makes one project reachable from another. `list_projects` reports exactly the reachable set; `ask_agent` to anything else is refused. Absent a link, an ask **fails closed**.

### Delivery

- **Connected + `wait_seconds`** → the ask long-polls and returns the answer inline.
- **Otherwise** → `{status:"pending", question_id}`; the question waits in the target's inbox until it calls `check_messages`.
- Outcomes (answer, expiry) are reported to the asker **exactly once**, so a session that reads one must record what matters.
- Nothing wakes a session that isn't running. Durability is the design: rows outlive processes.

## Repo integration

`RepoMCPInstaller.swift` owns the only file Dispatch writes in a user repo, and it is deliberately conservative:

1. **Value-faithful merge** — adds or replaces exactly one key, `dispatch`. Foreign servers and unknown top-level keys survive verbatim (BOM stripped, formatting re-serialized).
2. **We only delete what we created** — uninstall removes the `dispatch` key and nothing else.
3. **Name-collision guard** — an entry named `dispatch` whose URL does not have the shape Dispatch writes (`http`, `127.0.0.1`, a `/bus/` route — deliberately *not* the token's spelling) is a `conflict`, reported to the human, never clobbered.
4. **States**: `installed` / `stale` (right shape, wrong port or token) / `conflict` / absent.

The actor-per-installer exists so a token rotation and a repo re-scan cannot interleave on one file.

## Stores

All UI state lives in `@Observable @MainActor` stores under `Dispatch/Stores/`, composed by `AppStores`:

- **ProjectStore** — linked projects, git status, install state.
- **MessageStore** — the questions and answers the Messages tab renders.
- **CrossProjectStore** — links and the per-project request mirror.
- **ActivityStore** — the operation timeline behind the ticker.

`AppStores.live()` is async and runs off the synchronous `App` init: it bootstraps the databases, builds the router *before* the writers (destructive delete and unlink must close in-flight questions *through* the router — closing them in SQL alone would strand a long-polling caller), then wires the listener, notifications and sounds. `AppStores.mock()` swaps the whole lot for scripted fakes, which is what `--mock-scenario` runs on.

## Persistence

- **Global DB** — `~/Library/Application Support/Dispatch/global.sqlite`: `project`, `projectLink`, `projectBusToken`, `busMessage`.
- **Per-project DBs** — also under Application Support, **never anywhere inside the user's repo**.
- **Migrations** — `DatabaseMigrator` from day one; the locked-list test compares the *ordered* migrations array, because a Set cannot detect reordering.
- **Reads** — through the logged `safeRead` helpers in `PersistenceReading.swift`; never a bare `try?` on a read or write.
- **DTO boundary** — GRDB record types never cross into views; only the Sendable domain DTOs in `Dispatch/Models/DomainModels.swift` do.

## Git

Read-only, and only for what the project cards show. `GitClient` (an actor) shells to the `git` executable with `--porcelain=v2`, parsed by `GitPorcelainParser`, behind the `GitStatusProviding` protocol so tests inject a fake. `RepoBookmark` holds the security-scoped bookmark for a user-selected folder; `PathSafety` guards path handling. Dispatch never commits, never branches, never writes a worktree.

## Views

`ContentView` → `WorkbenchView`, with:

- **ProjectsRail** — project cards, bus health footer, resize handle.
- **Bus Map** (`Dispatch/Views/BusMap/`) — the switchboard, drawn: projects as stations, `projectLink` rows as lines, a traveling dot for each question or answer that crosses one.
- **Messages** — the question/answer inbox (`QuestionCardView`), plus the human's own answer path via `BusArbitrating`.
- **Modals** — link/edit project (including linking two projects to each other), delete project.
- **Settings** — General, Theme, Notifications.
- **Onboarding** — the first-run surface, gated on an empty registry.

Design tokens live in `Dispatch/DesignSystem/` (`Theme`, `Palette`, `Metrics`, `Motion`, `Shadows`, `TypeScale`). Outer chrome `#181A21` and canvas `#E7E8EC` are locked constants; only the accent is user-tunable.

## Concurrency

- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — every unannotated top-level declaration is implicitly `@MainActor`.
- Stores are `@Observable @MainActor`; services (listener, router seams, installer, GitClient, databases) are actors and never `@MainActor`.
- A protocol an actor conforms to must be declared `nonisolated protocol` — it bites hardest in test fakes.
- File-scope `private nonisolated let logger = Logger(subsystem: "com.wizemann.dispatch", category: …)`.
- Long-polls must never occupy the main actor.

Result: data flows one way (DB → store → view), actor boundaries are explicit, and the UI stays responsive while an ask waits.

---

_Last updated: 2026-07-30._
