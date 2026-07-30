// GlobalSchema.swift
// Migrations for the GLOBAL database — Dispatch's ONLY database: the projects
// registry, the links between projects, one bus token per project, and the one
// cross-project message table.
// ONE construction site: every global table is created here and nowhere else.
//
// Migration convention: identifiers are "vNNN_description", registered in order, and
// APPEND-ONLY FOREVER — never edit or reorder a shipped migration (this DB is the system
// of record; see .memory/decisions/decision-persistence-via-grdb). Tests lock the
// identifier list (PersistenceMigrationTests).

import Foundation
import GRDB
import os

private nonisolated let schemaLogger = Logger(subsystem: "com.wizemann.dispatch", category: "global-schema")

nonisolated enum GlobalSchema {

    /// UUIDs are stored as 16-byte BLOBs (GRDB's native UUID format); dates as
    /// "YYYY-MM-DD HH:MM:SS.SSS" TEXT; enums as their raw TEXT.
    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        // Dev convenience only. Shipped builds NEVER erase: migrations are owed forever.
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v001_initialSchema") { db in
            // Projects registry. GitStatus fields are a *rebuildable cache* of the last
            // live scan (instant sidebar paint on launch); nil until the first scan.
            try db.create(table: "project") { t in
                t.primaryKey("id", .blob)
                t.column("name", .text).notNull()
                t.column("repoPath", .text).notNull()
                t.column("repoBookmark", .blob)             // security-scoped bookmark
                t.column("pinned", .boolean).notNull().defaults(to: false)
                t.column("lastOpenedAt", .datetime)
                t.column("cachedBranch", .text)
                t.column("cachedOpenPRs", .integer)
                t.column("cachedOpenTickets", .integer)
                t.column("cachedUnpushedCommits", .integer)
            }
        }

        // A UNIQUE index on project.repoPath so two projects can NEVER share an exact
        // repoPath string — the DB-level backstop behind ProjectFormModel's form-level
        // duplicate guard. This matters for the scoped worktree sweep: without it, two
        // projects sharing a repoPath could see one deletion collateral-damage the
        // other's worktrees; with it, the shared-repoPath case simply cannot exist.
        //
        // DUPE HANDLING (fail-soft, chosen deliberately): CREATE UNIQUE INDEX
        // FAILS if duplicate repoPath rows already exist, which would BRICK the
        // whole DB open (every migration runs in one transaction). A user DB could
        // plausibly hold dupes today — the form guard is string-equality only and
        // self-documents that subfolder-vs-subfolder of one repo passes, and
        // repoPath never had a UNIQUE constraint. We must NOT destroy user project
        // rows to force the constraint through. So: detect dupes first; if any
        // exist, SKIP the index and log a warning (the form-layer guard stays the
        // only enforcement, exactly as before this migration) — a fail-soft skip
        // over a bricked DB or silent row deletion. A clean DB (the overwhelming
        // common case) gets the index and the hard guarantee.
        migrator.registerMigration("v002_projectRepoPathUnique") { db in
            let dupeCount = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM (
                        SELECT repoPath FROM project
                        GROUP BY repoPath HAVING COUNT(*) > 1
                    )
                    """
            ) ?? 0
            guard dupeCount == 0 else {
                schemaLogger.warning("v002: \(dupeCount, privacy: .public) duplicate repoPath value(s) present — SKIPPING the UNIQUE index (fail-soft; form-layer guard remains the enforcement, no rows deleted)")
                return
            }
            try db.create(
                index: "idx_project_repoPath_unique",
                on: "project", columns: ["repoPath"], unique: true
            )
        }

        // A link is an UNORDERED pair of registered project ids that lets either
        // project ask the other a question over the bus — the human-created
        // consent boundary an ask fails closed without. Rows are written
        // CANONICALLY (projectA.uuidString <= projectB.uuidString, enforced by
        // the ProjectLink mint), so a plain UNIQUE(projectA, projectB) index
        // rejects the same pair in EITHER order — one link per unordered pair.
        // No FK to `project`: link CRUD is store-layer, and a project deletion
        // prunes its links explicitly rather than via cascade.
        migrator.registerMigration("v003_projectLinks") { db in
            try db.create(table: "projectLink") { t in
                t.primaryKey("id", .blob)
                t.column("projectA", .blob).notNull()   // canonical low end
                t.column("projectB", .blob).notNull()   // canonical high end
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(
                index: "idx_projectLink_pair_unique",
                on: "projectLink", columns: ["projectA", "projectB"], unique: true
            )
        }

        // The bus core. Two tables, both GLOBAL because neither belongs to a
        // single project:
        //
        // `projectBusToken` — ONE durable bus endpoint identity per project.
        // The token is the URL path segment an external Claude Code session
        // POSTs to (http://127.0.0.1:<port>/bus/<token>), so the listener
        // resolves token → project before any MCP parsing happens. It is a
        // per-repo CONFIG value (it also lives in that repo's .mcp.json, which
        // the repo installer writes), not a user secret — hence a DB column
        // rather than the Keychain — and it is NEVER logged. The projectID
        // primary key is what makes rotation revoke: re-registering REPLACES
        // the row, so the old token resolves to nothing and a leaked config
        // goes dead. UNIQUE on the token itself is the collision backstop.
        //
        // `busMessage` — the ONE message table: correlation-ID question/answer
        // rows between two DIFFERENT projects (same-project Q&A cannot exist —
        // every bus caller IS a project). `deliveredAt` is RAW-SQL-ONLY and
        // kept OFF BusMessageRecord (the per-project busMessage convention) so
        // an ordinary row save can never clobber a live delivery mark.
        migrator.registerMigration("v004_busTokensAndMessages") { db in
            try db.create(table: "projectBusToken") { t in
                t.primaryKey("projectID", .blob)
                t.column("token", .text).notNull().unique()
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "busMessage") { t in
                t.primaryKey("id", .text)          // correlation id, "q-<hex>"
                t.column("fromProjectID", .blob).notNull()
                t.column("toProjectID", .blob).notNull()
                t.column("subject", .text).notNull()
                t.column("body", .text).notNull()
                t.column("status", .text).notNull()   // pending|answered|expired|closed
                t.column("answer", .text)
                t.column("answeredByHuman", .boolean).notNull().defaults(to: false)
                t.column("askedAt", .datetime).notNull()
                t.column("answeredAt", .datetime)
                t.column("deliveredAt", .datetime)    // raw-SQL-only
                // Raw-SQL-only too: when the ASKING project last saw this row's
                // outcome (answer or expiry) through check_messages. Durable so
                // an app relaunch never re-delivers an answer the asker already
                // read, and never swallows one it did not.
                t.column("answerSeenAt", .datetime)
                t.column("expiresAt", .datetime).notNull()
                t.column("closedReason", .text)
            }
            try db.create(indexOn: "busMessage", columns: ["toProjectID", "status"])
            try db.create(indexOn: "busMessage", columns: ["fromProjectID"])
        }

        // The per-project OPT-IN for the SessionStart / UserPromptSubmit nudge
        // hooks Dispatch merges into the repo's own `.claude/settings.json`.
        // Additive + backward-safe: existing rows read false, so no repo gains
        // a hooks file on upgrade.
        migrator.registerMigration("v005_projectSessionHooks") { db in
            try db.alter(table: "project") { t in
                t.add(column: "sessionHooksEnabled", .boolean).notNull().defaults(to: false)
            }
        }

        return migrator
    }
}
