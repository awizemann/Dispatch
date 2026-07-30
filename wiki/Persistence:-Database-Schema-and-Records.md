---
created: 2026-07-30
updated: 2026-07-30
source_sha: 4b184ef872b6a1d1473256df9ba78eddabb9b48a
source_paths: Dispatch/Persistence
source_paths_inferred: false
---

# Persistence: Database Schema and Records

Dispatch uses GRDB 7 (SQLite with WAL mode) for all durable state. This page documents the database setup, schema, record types, and query patterns.

## Database Setup

**Location:** `Dispatch/Persistence/GlobalDatabase.swift`, `Dispatch/Persistence/GlobalSchema.swift`, `Dispatch/Persistence/Persistence.swift`

The global database is created at `~/Library/Application Support/Dispatch/global.sqlite` on first launch. It is created fresh and migrated forward via `DatabaseMigrator` (defined in `GlobalSchema.swift`) on each app version.

All database operations are actor-isolated on `GlobalDatabase`, which owns the GRDB `DatabasePool`. Reads must go through the logged `safeRead` helper in `PersistenceReading.swift` — a bare `try?` is not permitted. This ensures logging and transaction semantics are correct.

## Global Schema

### ProjectRecord

**Struct:** `ProjectRecord` in `Dispatch/Persistence/GlobalRecords.swift:15`

Represents a linked repository:
- `id` (UUID, primary key)
- `name` (String, user-visible, editable)
- `path` (String, repo filesystem path, immutable after creation)
- `busToken` (String, 128-bit hex credential)
- `createdAt` (Date, immutable)
- `iconImageData` (Data?, optional cached project icon)

### projectLink

**Table:** defined in `GlobalSchema.swift`

Records the consent boundary between two projects. A row means the first project can ask the second one questions.

- `fromProjectID` (UUID, foreign key to ProjectRecord)
- `toProjectID` (UUID, foreign key to ProjectRecord)
- Composite primary key: `(fromProjectID, toProjectID)`

Only the human can create these rows via the app UI. `ask_agent` checks this table before routing a question; absence of a link means refusal.

### BusMessageRecord

**Struct:** `BusMessageRecord` in `Dispatch/Persistence/GlobalRecords.swift:90`

Stores every question and answer on the bus:
- `id` (UUID, question or answer identifier)
- `fromProjectID` (UUID, who asked or who answered)
- `toProjectID` (UUID, who was asked or who is answering)
- `kind` (String: "question" or "answer")
- `text` (String, up to 16,384 characters, the question or answer text)
- `status` (String: "open", "answered", or "expired")
- `outcome` (String?, populated when answered or expired — contains the answer text or expiry reason)
- `createdAt` (Date)
- `expiresAt` (Date, typically 1 week in the future, for TTL-based cleanup)
- `seen` (Bool, marks whether the outcome has been reported to the asking project)

The router uses this table for:
- Durable storage of every ask before attempting delivery
- Inbox assembly — fetch rows where `toProjectID` matches and `status == "open"`
- Outcome tracking — find rows where `fromProjectID` matches and `outcome is not null` and `seen == false`
- TTL cleanup — periodically delete rows where `expiresAt < now`

## Query Patterns

### Assembling an Inbox

```swift
let inbox = try await db.read { db in
  try BusMessageRecord
    .where(Column("toProjectID") == projectID)
    .where(Column("status") == "open")
    .fetchAll(db)
}
```

This returns all open questions addressed to a project.

### Finding Unseen Outcomes

```swift
let outcomes = try await db.read { db in
  try BusMessageRecord
    .where(Column("fromProjectID") == projectID)
    .where(Column("outcome").notNull())
    .where(Column("seen") == false)
    .fetchAll(db)
}
```

This returns every unseen answer or expiry for a project's own questions.

### Expiry Cleanup

```swift
try await db.write { db in
  try db.execute(
    sql: "DELETE FROM \(BusMessageRecord.databaseTableName) WHERE expiresAt < ?1",
    arguments: [Date.now]
  )
}
```

This removes stale messages older than their TTL.

## Constraints and Invariants

- A `projectLink` row is the **only** thing that makes one project reachable from another. Absence of a link means `ask_agent` fails closed.
- The `busToken` in `ProjectRecord` is a credential and must never reach a log, error message, or test output. It lives only in the URL written into `.mcp.json`.
- A `BusMessageRecord` is immutable once created — only `status`, `outcome`, and `seen` flags change; the question text itself never changes.
- Foreign keys are enforced: deleting a project cascades to delete its links and messages.
- `expiresAt` is always set on creation (typically `now + 1 week`), and expired rows are cleaned up periodically by a background task, not immediately.

See [[memophant/conventions/grdb-persistence-layer-gotchas]] for concurrency semantics, particularly around Task cancellation in debounce routines.

---

_Last updated: 2026-07-30 — new_