// PersistenceRoundTripTests.swift
// DTO → record → row → record → DTO round-trips through the persistence actor.
//
// Discriminating power: the fixtures exercise the lossy-looking corners of the
// mapping — the git cache flattened into four nullable columns, the bookmark that
// lives beside a whole-record save, and the bus row's raw-SQL-only delivery marks.
// A mapping that drops or defaults any of these fails the equality checks.

import Foundation
import GRDB
import Testing
@testable import DispatchApp

@Suite("Persistence round-trips")
struct PersistenceRoundTripTests {

    // MARK: Global

    @Test("Project round-trips; git cache is nil until first scan, then persists")
    func projectRoundTripAndGitCache() async throws {
        let db = try await GlobalDatabase.openInMemory()
        let project = Project(id: UUID(), name: "Dispatch", repoPath: "/tmp/repo",
                              pinned: true, git: nil, lastOpenedAt: nil)
        try await db.saveProject(project)
        #expect(try await db.fetchProjects() == [project])

        let git = GitStatus(openPRs: 3, openTickets: 7, unpushedCommits: 2, branch: "main")
        try await db.updateGitStatusCache(projectID: project.id, git: git)
        let reloaded = try await db.fetchProjects()
        #expect(reloaded.first?.git == git)
    }

    @Test("Repo bookmark survives project re-save")
    func bookmarkSurvivesResave() async throws {
        let db = try await GlobalDatabase.openInMemory()
        var project = Project(id: UUID(), name: "A", repoPath: "/a",
                              pinned: false, git: nil, lastOpenedAt: nil)
        try await db.saveProject(project)
        let bookmark = Data([0xDE, 0xAD, 0xBE, 0xEF])
        try await db.saveRepoBookmark(projectID: project.id, bookmark: bookmark)
        project.name = "A renamed"
        try await db.saveProject(project)   // must not clobber the bookmark
        #expect(try await db.repoBookmark(projectID: project.id) == bookmark)
    }

    // MARK: Bus (global)

    @Test("A bus question round-trips through the global table with every field intact")
    func busMessageRoundTrip() async throws {
        let db = try await GlobalDatabase.openInMemory()
        let message = BusMessage(
            id: BusMessage.mintID(), from: UUID(), to: UUID(),
            subject: "Cursor shape?", body: "Opaque or a tuple?",
            askedAt: Fixtures.date(), expiresAt: Fixtures.date(offset: 86_400)
        )
        try await db.saveBusMessage(message)
        #expect(try await db.fetchBusMessages() == [message])
        #expect(try await db.fetchBusMessage(id: message.id) == message)
    }

    @Test("A bus token is minted once per project, is stable, and rotation replaces it")
    func busTokenLifecycle() async throws {
        let db = try await GlobalDatabase.openInMemory()
        let projectID = UUID()
        let first = try await db.busToken(projectID: projectID)
        #expect(first.count == 32, "128 bits, hex-encoded")
        #expect(try await db.busToken(projectID: projectID) == first,
                "the token is DURABLE — the repo's .mcp.json entry must keep working")
        #expect(try await db.projectID(forBusToken: first) == projectID)

        let rotated = try await db.rotateBusToken(projectID: projectID)
        #expect(rotated != first)
        #expect(try await db.projectID(forBusToken: first) == nil,
                "rotation REVOKES: the old token resolves to nothing")
        #expect(try await db.projectID(forBusToken: rotated) == projectID)

        try await db.deleteBusToken(projectID: projectID)
        #expect(try await db.projectID(forBusToken: rotated) == nil)
    }
}
