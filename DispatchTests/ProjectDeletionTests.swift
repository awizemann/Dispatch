// ProjectDeletionTests.swift
// Pins the destructive-delete ORCHESTRATION with fakes — no real
// subprocesses or files. The safety invariants the audit attacks hardest:
//   1. Fixed order: DB file → bookmark → registry LAST.
//   2. Partial-failure tolerance: a throwing backing step never aborts the run;
//      the registry row still deletes last. A registry throw surfaces (retry).
//   3. Path-derivation safety: every Dispatch-owned file lives under Application
//      Support, NEVER inside the user's repo root.

import Foundation
import Testing
@testable import DispatchApp

@Suite("Project deletion orchestration")
struct ProjectDeletionTests {

    /// Records every step in call order.
    private actor Recorder {
        var steps: [String] = []
        func log(_ step: String) { steps.append(step) }
    }

    private func makeSteps(
        recorder: Recorder,
        dbThrows: Bool = false,
        registryThrows: Bool = false
    ) -> ProjectDeletionSteps {
        struct StepError: Error {}
        return ProjectDeletionSteps(
            deleteProjectDatabase: { _ in
                await recorder.log("db")
                if dbThrows { throw StepError() }
            },
            releaseBookmark: { _ in await recorder.log("bookmark") },
            deleteRegistryRow: { _ in
                await recorder.log("registry")
                if registryThrows { throw StepError() }
            }
        )
    }

    @Test("Steps run in the fixed order with the registry row LAST")
    func fixedOrder() async throws {
        let recorder = Recorder()
        let deletion = ProjectDeletion(steps: makeSteps(recorder: recorder))

        try await deletion.run(projectID: UUID())

        #expect(await recorder.steps == ["db", "bookmark", "registry"])
        // The registry row is the final, decisive act.
        #expect(await recorder.steps.last == "registry")
    }

    @Test("A DB-delete failure is swallowed — the registry row STILL deletes last")
    func dbFailureStillDeletesRegistry() async throws {
        let recorder = Recorder()
        let deletion = ProjectDeletion(steps: makeSteps(recorder: recorder, dbThrows: true))

        // No throw: the backing-cleanup failure is best-effort.
        try await deletion.run(projectID: UUID())

        let steps = await recorder.steps
        #expect(steps == ["db", "bookmark", "registry"],
                "a DB failure must not skip bookmark or registry")
        #expect(steps.last == "registry", "the project must never stay registered when its backing state is gone")
    }

    @Test("A registry-row failure surfaces (so the project stays listed for retry)")
    func registryFailureSurfaces() async throws {
        let recorder = Recorder()
        let deletion = ProjectDeletion(steps: makeSteps(recorder: recorder, registryThrows: true))

        await #expect(throws: (any Error).self) {
            try await deletion.run(projectID: UUID())
        }
        // Every earlier step still ran — only the final act failed.
        #expect(await recorder.steps == ["db", "bookmark", "registry"])
    }

    // MARK: - Path-derivation safety

    @Test("Dispatch's own storage root is Application-Support-owned, never a user repo")
    func storageRootIsDispatchOwned() throws {
        let path = try DatabaseLocations.rootDirectory().path

        #expect(path.hasSuffix("/Application Support/\(AppInfo.name)"))
        // NEVER anywhere near a user repo checkout.
        #expect(!path.contains("/repos/"))
        #expect(!path.contains(".dispatch/worktrees"))
        // The one database lives directly inside it.
        #expect(try DatabaseLocations.globalDatabaseURL().path == path + "/global.sqlite")
    }
}
