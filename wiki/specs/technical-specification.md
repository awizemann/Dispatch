---
title: Technical Specification
created: 2026-07-05
updated: 2026-07-30
source_sha: 4738c8d1f4cb39ace4c5dd75abca831026d7cb9e
source_paths: Dispatch/Services, Dispatch/Stores, Dispatch/Views, Dispatch/Persistence, Dispatch/Models
source_paths_inferred: false
---

# Technical Specification

> **Status:** this page has been *trimmed*, not re-specified, to describe only what Dispatch actually ships — a bus with four verbs between linked projects. Sections describing a larger, unreleased product (an agent runtime, a work queue, a commit gate, a QA pipeline, a chat surface, a secret scanner, a GitHub client, accounts) have been removed because none of that exists here. A full respec is a later arc — until then, [Architecture Overview](Architecture-Overview) is the fuller picture and the code is the authority.

Target: macOS 26+, Swift 6.2 (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`), Xcode 27 beta, non-sandboxed Developer ID app. Decisions behind each choice live in `.memory/decisions/`.

## Layer map

```
SwiftUI views (design system in Dispatch/DesignSystem/)
   │  Sendable DTOs only — no persistence type ever crosses this line
@Observable @MainActor domain stores
   (AppStores → ProjectStore, MessageStore, CrossProjectStore, ActivityStore)
   │  nonisolated protocol seams (PersistenceReading, GitStatusProviding,
   │  BusArbitrating, SoundPlaying)
Actors / services
   ├─ MCPBusListener   (SwiftNIO HTTP, 127.0.0.1:<kernel port>, /bus/<token>)
   ├─ DispatchEndpoint (one MCP swift-sdk Server per project identity)
   ├─ DispatchRouter   (ask / answer / inbox / long-poll / expiry / links)
   ├─ RepoMCPInstaller (actor; owns the "dispatch" key in a repo's .mcp.json)
   ├─ GitClient        (git executable via swift-subprocess, --porcelain=v2)
   └─ GlobalDatabase / project databases (GRDB 7, DatabaseMigrator)
        ▲
   the user's OWN claude sessions connect as MCP clients over http
```

## MCP bus

See [How Dispatch Works](How-Dispatch-Works) and [The Four Verbs](The-Four-Verbs) for the narrative version of this section.

The app hosts **one** MCP server for the whole process and gives each linked project an identity on it. The clients are Claude Code sessions the user starts themselves — Dispatch spawns nothing.

**Tools served (the complete surface):**

| Tool | Arguments | Behavior |
| --- | --- | --- |
| `ask_agent` | `project`, `question`, `wait_seconds?` | Ask a LINKED project. Target connected + `wait_seconds` → the answer returns inline; otherwise `{status:"pending", question_id}`. A target that is not linked is refused. |
| `answer_agent` | `question_id`, `answer` | Answer a question addressed to THIS project. Only the addressee may answer. Already-answered or expired questions are refused, never silently overwritten. |
| `check_messages` | — | Inbox: questions waiting on this project, plus every unseen outcome of its own asks (answers, expiries). Outcomes are reported **exactly once**. |
| `list_projects` | — | The linked set — the only reachable projects. Reports live-connected state, last-seen, and inbox depth per peer. |

**Auth and identity.** One durable 128-bit token per project (global DB table `projectBusToken`), embedded in the URL written into that repo's `.mcp.json`. The token is the route: `MCPBusListener` resolves `/bus/<token>` → project before any MCP parsing happens, and each endpoint's handlers close over a fixed identity. Nothing is asserted in a header, so nothing can be spoofed. Rotation revokes the route and rewrites the entry.

**Consent.** A human-created `projectLink` row is the boundary. `ask_agent` to an unlinked project **fails closed**. Agents cannot create links.

**Framing.** Every value from another repo is folded through `BusTextSanitizer` before it reaches a framing line (`sanitizeLine`), and bodies ride inside fences as DATA, never instructions. `BusProtocolText` / `BusEventText` hold the protocol prose.

## Repo integration

See [Linking Projects](Linking-Projects) for the narrative version of this section.

`RepoMCPInstaller` merges exactly one key into the repo's `.mcp.json`:

```json
{ "mcpServers": { "dispatch": { "type": "http",
  "url": "http://127.0.0.1:<port>/bus/<token>" } } }
```

Value-faithful (foreign servers and unknown top-level keys survive verbatim, BOM stripped); uninstall removes only what we created; an entry named `dispatch` that does not have the shape Dispatch writes (`http`, `127.0.0.1`, a `/bus/` route — deliberately not the token's spelling) is reported as a **conflict**, never clobbered. States: `installed` / `stale` / `conflict` / absent. The installer is an actor so a rotation and a re-scan cannot interleave on one file.

The listener re-binds its persisted port on later launches, because every `.mcp.json` already on disk points at it.

## Persistence

- GRDB 7, WAL, `DatabasePool`. Global DB at `~/Library/Application Support/Dispatch/global.sqlite` (`project`, `projectLink`, `projectBusToken`, `busMessage`); per-project databases also under Application Support — **never inside the user's repo**.
- The DB is the **system of record** for bus state → migrations owed forever; the locked-list test compares the *ordered* `DatabaseMigrator.migrations` array (a Set cannot detect reordering).
- Reads go through the logged `safeRead` helpers in `PersistenceReading.swift`; never a bare `try?`.
- Structs with autoincremented ids conform to `MutablePersistableRecord`, not `PersistableRecord`.

## Git

Read-only. `GitClient` (actor) shells to `git status --porcelain=v2` via swift-subprocess, parsed by `GitPorcelainParser`, behind `GitStatusProviding`. `LC_ALL=C` pinned (git localizes fatal messages), plus `GIT_TERMINAL_PROMPT=0` and `GIT_OPTIONAL_LOCKS=0`. Porcelain v2 `--branch` gives upstream presence for free. `RepoBookmark` holds the security-scoped bookmark; `PathSafety` guards path handling. Dispatch never commits, branches, or writes a worktree.

## Design system

Tokens in `Dispatch/DesignSystem/`: `Theme`, `Palette`, `Metrics`, `Motion`, `Shadows`, `TypeScale`. Outer chrome `#181A21` and canvas `#E7E8EC` are locked `let` constants; only the accent is user-tunable (5 curated swatches). Off-scale fonts use `TextStyle(TypeScale.ui(N, .weight))`, never raw `.font(.system(size:))`. No raw `Color(hex:)` where a token exists.

## Testing

- Swift Testing (`@Suite` / `@Test` / `#expect`), not XCTest. App-hosted suites run in Debug.
- Protocol-driven actor fakes injected by parameter; a protocol an actor fake conforms to must be `nonisolated protocol`.
- Mock seam: actor fakes over the `PersistenceReading` protocols with initial-emission-then-yields broadcast, mimicking GRDB `ValueObservation`. `--mock-scenario` runs the whole app on them.
- No timing-dependent tests: await a real drain seam, never sleep-then-assert.
- Tests must be discriminating — state in the test or commit how you know it fails on the broken code.

## Building and signing

- `./scripts/build.sh` — Release compile check first (`#Preview` bodies are type-checked in Release), then Debug `build test`. Isolated DerivedData `/tmp/dispatch-ci-dd`; `DEVELOPER_DIR` pinned to `/Applications/Xcode-beta.app/Contents/Developer`; `-skipMacroValidation`.
- `./scripts/build-detached.sh` — visually distinct dogfood copy.
- Commit gating is structural: chain `./scripts/build.sh && git add … && git commit …` so a commit cannot run on a red build.
- All configs sign Developer ID Application, Manual, team 3Q6X2L86C4. Debug hardened runtime OFF, Release ON. See `scripts/SIGNING.md`.

## Dependencies

| Package | Version | Use |
| --- | --- | --- |
| GRDB.swift | 7.11.1 | SQLite persistence |
| modelcontextprotocol/swift-sdk | 0.12.1 | MCP server |
| swift-nio | 2.101.2 | the localhost HTTP listener |
| swift-subprocess | 0.5.0 | git shell-out |
| Defaults | 8.2.0 | preferences |

Plus their transitive deps (swift-atomics, swift-collections, swift-log, swift-system, eventsource). All MIT/Apache; none GPL. swift-sdk and swift-subprocess are pre-1.0 — pinned.

## Error handling

- Catch → log (`logger.error` / `.warning`) → re-throw or return `.failure`. Never a silent `try?` except for truly ignorable ops.
- `logger.warning` for expected conditions (file missing, timeout); `logger.error` for the unexpected.
- No `print()` in production; `os.Logger` only, subsystem `com.wizemann.dispatch`, declared file-scope as `private nonisolated let logger`.
- Logs never carry repo file contents, question/answer bodies, or the bus token.
- Database locks are `.warning` (expected under concurrent load).

---

_Last updated: 2026-07-30 — trimmed to the switchboard; full respec pending._
