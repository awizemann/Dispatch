---
created: 2026-07-30
updated: 2026-07-30
source_sha: 4b184ef872b6a1d1473256df9ba78eddabb9b48a
source_paths: Dispatch/Services/MCPBus, Dispatch/Services, Dispatch/Persistence/GlobalDatabase.swift
source_paths_inferred: false
---

# Services and Actors

The core of Dispatch beyond the views layer is a collection of actor services that implement the bus, manage persistent state, and integrate with the filesystem. This page describes each major service's role and responsibilities.

## MCPBusListener

**Location:** `Dispatch/Services/MCPBus/MCPBusListener.swift`

The entry point for all bus traffic. `MCPBusListener` is a single SwiftNIO HTTP server bound to `127.0.0.1` on a kernel-assigned port. It answers the route `POST /bus/<token>` where the token is a project's unique 128-bit identifier. Identity resolution happens *before* MCP parsing: an unknown or revoked token is a 404, full stop.

On app startup, the listener picks a port and remembers it so every subsequent restart re-binds the same port — each `.mcp.json` on disk already points at it. It spawns one `DispatchEndpoint` per linked project on demand and keeps endpoints alive for the lifetime of that project link.

## DispatchEndpoint

**Location:** `Dispatch/Services/MCPBus/DispatchEndpoint.swift`

One MCP `Server` per project, built on the official modelcontextprotocol/swift-sdk. Its tool handlers are closed over that project's fixed identity — project A's endpoint cannot be reached from project B, and the tools always know who they're serving. The four MCP tools (see [The Four Verbs](The-Four-Verbs)) delegate all logic to a shared `DispatchRouter` instance.

The endpoint is where the MCP protocol frame meets the Dispatch domain; it parses arguments, wraps errors, and frames responses. It also enforces the consent boundary before any tool: verifying that the target project is linked before allowing an ask.

## DispatchRouter

**Location:** `Dispatch/Services/MCPBus/DispatchRouter.swift`

The brain of the bus. The router implements the business logic for all four MCP tools and owns:

- **Question durability** — every ask is written to `GlobalDatabase` before attempting delivery
- **Project linkage** — fail-closed consent checking that refuses asks to projects outside the caller's linked set
- **Long-polling** — when an ask arrives with `wait_seconds`, the router parks the caller and waits for an answer to arrive or the timeout to expire
- **Inbox assembly** — gathering open questions addressed to a project, plus every unseen outcome (answer or expiry) of its own asks
- **Exactly-once outcome delivery** — marking outcomes seen after reporting so they're never reported twice
- **Message framing and sanitization** — every value from another repo rides through `BusTextSanitizer` before it lands on a framing line

See [How Dispatch Works](How-Dispatch-Works) for the narrative walkthrough of the router's request flow.

## GitClient

**Location:** `Dispatch/Services/GitClient.swift`

An actor that shells out to the git executable with `swift-subprocess` to read repository status. It runs `git status --porcelain=v2` and parses the output into a `GitSnapshot` struct containing:

- Current branch name
- Whether the branch is behind, ahead, or in sync with the remote
- Dirty file count (unstaged changes)
- Unpushed count (local commits not yet pushed)

Calls are cached briefly to avoid hammering the filesystem on every view update. See [[memophant/conventions/subprocess-and-git-integration-gotchas]] for the integration details (subprocess limits, signal handling, stdout parsing).

## GlobalDatabase

**Location:** `Dispatch/Persistence/GlobalDatabase.swift`

An actor that owns the app-wide GRDB database (SQLite, WAL mode). It stores:

- **Projects** — `ProjectRecord` holds name, path, bus token, creation timestamp, and optional cached icon data
- **Project links** — the consent boundary between two projects (a row means A can ask B)
- **Bus messages** — `BusMessageRecord` stores every question and answer, with status, timestamps, and text
- **Settings** — user preferences for notifications, sounds, theme, etc.

All database writes are managed by migrations in `GlobalSchema.swift`. Reads always go through the logged `safeRead` helpers in `PersistenceReading.swift` — never bare `try?` on a database read. See [[memophant/conventions/grdb-persistence-layer-gotchas]] for concurrency rules around Task cancellation.

## RepoMCPInstaller

**Location:** `Dispatch/Services/MCPBus/RepoMCPInstaller.swift`

An actor that owns the merge of the `dispatch` key into a linked repo's `.mcp.json`. It guarantees:

- **Value-faithful merge** — only the `dispatch` key under `mcpServers` is added or replaced; every other server and every unknown top-level key round-trips untouched, byte-for-byte
- **Conflict detection** — a foreign `dispatch` server (one Dispatch didn't create) is flagged as a conflict rather than overwritten
- **Uninstall safety** — removing a project deletes only the `dispatch` key; the file itself is deleted only if Dispatch created it
- **Token rotation** — when a token is rotated or a project is deleted, the entry is rewritten immediately
- **Gitignore hygiene** — if Dispatch created `.mcp.json`, it adds a marked line to `.gitignore` so the token is never committed; if `.mcp.json` pre-existed, Dispatch leaves `.gitignore` alone

The contract is formalized in [[memophant/architecture/repo-install-architecture-mcp-json-merge-contract]].

## NotificationPoster and SoundPlayer

**Location:** `Dispatch/Services/Notifications/`

`NotificationPoster` sends macOS system notifications (OS notification center) when a question or answer arrives. `SoundPlayer` plays app feedback sounds at user-configurable volume. The sound mapping is documented in [[memophant/decisions/decision-app-feedback-sounds-v2-three-sounds-class-mapping]]: `.question` when a question arrives, `.answer` when an answer arrives.

---

_Last updated: 2026-07-30 — new_