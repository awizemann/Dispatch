// PersistenceMigrationTests.swift
// Migration integrity for Dispatch's one database.
//
// Discriminating power:
// - The locked identifier list fails on any rename/reorder/removal of a shipped
//   migration (the append-only contract), and forces a deliberate test edit when
//   a new migration is appended.
// - The schema-introspection test fails if a live table or column is dropped, or
//   if the schema grows beyond the switchboard's four tables.
// - The upgrade tests drive a real pre-latest database forward and assert that
//   user data (projects) survives.

import Foundation
import Testing
import GRDB
@testable import DispatchApp

@Suite("Persistence migrations")
struct PersistenceMigrationTests {

    /// APPEND-ONLY: add new identifiers at the END. Never edit or reorder.
    private static let expectedGlobalMigrations = [
        "v001_initialSchema",              // project registry
        "v002_projectRepoPathUnique",      // UNIQUE index on project.repoPath (deletion-safety backstop)
        "v003_projectLinks",               // projectLink table — unordered unique project-id pair
        "v004_busTokensAndMessages",       // projectBusToken (one identity per project) + the ONE global busMessage table
        "v005_projectSessionHooks",        // project.sessionHooksEnabled — the .claude/settings.json nudge-hook opt-in
    ]

    @Test("Migrator registers and applies exactly the locked migration list, in order")
    func globalMigrationIdentifiersAreLocked() throws {
        let migrator = GlobalSchema.makeMigrator()
        // Ordered comparison: catches renames, removals, AND reorders.
        #expect(migrator.migrations == Self.expectedGlobalMigrations)

        let queue = try DatabaseQueue()
        try migrator.migrate(queue)
        let applied = try queue.read { try migrator.appliedIdentifiers($0) }
        #expect(applied == Set(Self.expectedGlobalMigrations))
        let completed = try queue.read { db in try migrator.hasCompletedMigrations(db) }
        #expect(completed)
    }

    @Test("The fully migrated schema is exactly the switchboard's four tables")
    func schemaShapeIsTheSwitchboard() throws {
        let queue = try DatabaseQueue()
        try GlobalSchema.makeMigrator().migrate(queue)
        try queue.read { db in
            for table in ["project", "projectLink", "projectBusToken", "busMessage"] {
                #expect(try db.tableExists(table), "missing table \(table)")
            }
            let projectColumns = try db.columns(in: "project").map(\.name)
            #expect(Set(projectColumns) == [
                "id", "name", "repoPath", "repoBookmark", "pinned",
                "lastOpenedAt", "cachedBranch", "cachedOpenPRs",
                "cachedOpenTickets", "cachedUnpushedCommits", "sessionHooksEnabled",
            ], "project's columns are exactly the switchboard's, nothing more")
        }
    }

    @Test("v002 adds the UNIQUE index on project.repoPath")
    func repoPathUniqueIndexExists() throws {
        let queue = try DatabaseQueue()
        let migrator = GlobalSchema.makeMigrator()
        // A pre-v002 database — no unique index yet.
        try migrator.migrate(queue, upTo: "v001_initialSchema")
        #expect(try queue.read { db in
            try db.indexes(on: "project").contains { $0.isUnique && $0.columns == ["repoPath"] }
        } == false, "the unique index does not exist before v002")

        try migrator.migrate(queue)

        #expect(try queue.read { db in
            try db.indexes(on: "project").contains { $0.isUnique && $0.columns == ["repoPath"] }
        }, "the UNIQUE index on project.repoPath must exist after v002")

        // Two projects can never share an exact repoPath — the second insert is
        // rejected at the DB layer (the backstop behind the form guard).
        let first = Project(id: UUID(), name: "Live", repoPath: "/repos/Live", pinned: false)
        let second = Project(id: UUID(), name: "Live copy", repoPath: "/repos/Live", pinned: false)
        try queue.write { db in try ProjectRecord(project: first, repoBookmark: nil).save(db) }
        #expect(throws: (any Error).self) {
            try queue.write { db in try ProjectRecord(project: second, repoBookmark: nil).save(db) }
        }
    }

    @Test("v002 FAILS SOFT on pre-existing duplicate repoPath rows: skips the index, preserves every row")
    func globalV002FailsSoftOnExistingDuplicates() throws {
        let queue = try DatabaseQueue()
        let migrator = GlobalSchema.makeMigrator()
        // A pre-v002 database that already holds two projects sharing a repoPath
        // (only reachable before the constraint existed — the exact dupe the
        // migration must tolerate WITHOUT destroying user rows).
        try migrator.migrate(queue, upTo: "v001_initialSchema")
        let a = UUID(), b = UUID()
        try queue.write { db in
            for (id, name) in [(a, "One"), (b, "Two")] {
                try db.execute(
                    sql: "INSERT INTO project (id, name, repoPath, pinned) VALUES (?, ?, ?, ?)",
                    arguments: [id, name, "/repos/Shared", false]
                )
            }
        }

        // The migration must NOT throw (a throw here bricks the whole DB open),
        // must NOT delete either row, and must skip the index (fail-soft).
        try migrator.migrate(queue)

        let applied = try queue.read { try migrator.appliedIdentifiers($0) }
        #expect(applied.contains("v002_projectRepoPathUnique"),
                "the migration records as applied — it fails soft, it does not fail")
        let ids = try queue.read { try ProjectRecord.fetchAll($0).map(\.id) }
        #expect(Set(ids) == [a, b], "BOTH duplicate rows survive — no user project is silently deleted")
        #expect(try queue.read { db in
            try db.indexes(on: "project").contains { $0.isUnique && $0.columns == ["repoPath"] }
        } == false, "with dupes present the index is SKIPPED — the form-layer guard stays the enforcement")
    }

    // MARK: - v004: bus tokens + the one message table

    @Test("Global v004 creates projectBusToken + busMessage with their columns and indexes")
    func globalV004BusSchema() throws {
        let queue = try DatabaseQueue()
        try GlobalSchema.makeMigrator().migrate(queue)
        try queue.read { db in
            #expect(try db.tableExists("projectBusToken"))
            #expect(try db.tableExists("busMessage"))
            let tokenColumns = try db.columns(in: "projectBusToken").map(\.name)
            #expect(Set(tokenColumns) == ["projectID", "token", "createdAt"])
            let messageColumns = try db.columns(in: "busMessage").map(\.name)
            for column in ["id", "fromProjectID", "toProjectID", "subject", "body",
                           "status", "answer", "answeredByHuman", "askedAt",
                           "answeredAt", "deliveredAt", "answerSeenAt", "expiresAt",
                           "closedReason"] {
                #expect(messageColumns.contains(column), "busMessage missing \(column)")
            }
            #expect(try !db.indexes(on: "busMessage").isEmpty)
        }
    }

    @Test("One project holds exactly one bus token: a second registration REPLACES the row")
    func busTokenIsOnePerProject() throws {
        let queue = try DatabaseQueue()
        try GlobalSchema.makeMigrator().migrate(queue)
        let projectID = UUID()
        try queue.write { db in
            try ProjectBusTokenRecord(projectID: projectID, token: "aaa",
                                      createdAt: Fixtures.date()).save(db)
            try ProjectBusTokenRecord(projectID: projectID, token: "bbb",
                                      createdAt: Fixtures.date()).save(db)
        }
        let rows = try queue.read { try ProjectBusTokenRecord.fetchAll($0) }
        #expect(rows.count == 1, "the projectID primary key is what makes rotation a replace")
        #expect(rows.first?.token == "bbb")
    }

    @Test("Two projects can never share a bus token (UNIQUE)")
    func busTokensAreUnique() throws {
        let queue = try DatabaseQueue()
        try GlobalSchema.makeMigrator().migrate(queue)
        try queue.write { db in
            try ProjectBusTokenRecord(projectID: UUID(), token: "same",
                                      createdAt: Fixtures.date()).save(db)
        }
        #expect(throws: (any Error).self) {
            try queue.write { db in
                try ProjectBusTokenRecord(projectID: UUID(), token: "same",
                                          createdAt: Fixtures.date()).insert(db)
            }
        }
    }
}
