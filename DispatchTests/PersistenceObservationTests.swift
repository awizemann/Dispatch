// PersistenceObservationTests.swift
// ValueObservation → AsyncThrowingStream delivery of Sendable DTOs.
//
// Discriminating power: the consumer collects every emission into a locked box and
// the test polls with early exit (testing-standards rule — never sleep-then-assert).
// If observation never emits the initial state, or never re-emits after a write
// lands, the poll exhausts and the test fails. The change emission is asserted by
// VALUE (the exact DTO written), so a stream wired to the wrong table or a mapping
// that mangles the record also fails.

import Foundation
import Testing
@testable import DispatchApp

@Suite("Persistence observation")
struct PersistenceObservationTests {

    @Test("Bus-message observation emits initial state, then the answered row")
    func busMessageObservationDeliversChange() async throws {
        let db = try await GlobalDatabase.openInMemory()
        let message = BusMessage(
            id: BusMessage.mintID(), from: UUID(), to: UUID(),
            subject: "s", body: "Opaque or a tuple?",
            askedAt: Fixtures.date(), expiresAt: Fixtures.date(offset: 86_400)
        )
        try await db.saveBusMessage(message)

        let received = LockedBox<[[BusMessage]]>([])
        let stream = await db.observeBusMessages()
        let consumer = Task {
            for try await messages in stream {
                received.mutate { $0.append(messages) }
            }
        }
        defer { consumer.cancel() }

        #expect(try await pollUntil { received.value.contains([message]) })

        _ = try await db.recordBusAnswer(
            id: message.id, answeringProjectID: message.to,
            answer: "Opaque.", byHuman: false, now: Fixtures.date(offset: 60)
        )
        #expect(try await pollUntil {
            received.value.contains { $0.first?.status == .answered && $0.first?.answer == "Opaque." }
        }, "observation never delivered the answered row")
    }


    @Test("Global project observation reflects git-cache updates")
    func projectObservationDeliversCacheUpdate() async throws {
        let db = try await GlobalDatabase.openInMemory()
        let project = Project(id: UUID(), name: "Dispatch", repoPath: "/tmp/repo",
                              pinned: false, git: nil, lastOpenedAt: nil)
        try await db.saveProject(project)

        let received = LockedBox<[[Project]]>([])
        let stream = await db.observeProjects()
        let consumer = Task {
            for try await projects in stream {
                received.mutate { $0.append(projects) }
            }
        }
        defer { consumer.cancel() }

        #expect(try await pollUntil { received.value.contains([project]) })

        let git = GitStatus(openPRs: 1, openTickets: 0, unpushedCommits: 4, branch: "main")
        try await db.updateGitStatusCache(projectID: project.id, git: git)

        var expected = project
        expected.git = git
        #expect(try await pollUntil { received.value.contains([expected]) },
                "observation never delivered the git-cache update")
    }
}
