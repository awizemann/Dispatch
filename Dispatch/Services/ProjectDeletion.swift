// ProjectDeletion.swift
// The orchestration for DELETING a project — the destructive
// inverse of ProjectStore.addProject. Pure and injectable: every side effect
// is a closure, so the ORDER and the fault-tolerance semantics are pinned by
// store-level tests with fakes, zero real subprocesses or files.
//
// SAFETY CONTRACT (the audit attacks these hardest):
//  - Deletion removes ONLY Dispatch's own state: the per-project DB file(s),
//    the security-scoped bookmark, and the global registry row. The user's
//    actual repository is NEVER touched.
//  - ORDER is fixed and load-bearing:
//      1. delete the per-project DB (close connections, then unlink files)
//      2. release the bookmark      (drop the security-scoped access record)
//      3. delete the registry row   (the FINAL, decisive act)
//  - Steps 1–2 (backing cleanup) are BEST-EFFORT and per-item fault-tolerant:
//    a throw in any one is logged and swallowed so the rest still run. We never
//    abort a half-done teardown.
//  - Step 3 (registry row) runs LAST and is the one throwing step. Rationale:
//    the registry row is what makes a project VISIBLE. Removing it last means
//    we never leave a registered project whose backing state is half-gone —
//    the row's disappearance is the atomic "this project is gone" signal. If
//    the row delete itself fails, the project is still listed (backing state
//    partly gone) and the error surfaces so the user can retry — deletion is
//    idempotent, so a retry safely re-runs every step.

import Foundation
import os

private nonisolated let deletionLogger = Logger(subsystem: "com.wizemann.dispatch", category: "project-deletion")

/// The injectable side-effect surface for deleting one project. The live
/// composition (AppStores) wires these over DatabaseManager, GlobalDatabase,
/// and RepoBookmark; tests wire fakes that record call order.
nonisolated struct ProjectDeletionSteps: Sendable {
    /// 0. Take Dispatch's `dispatch` entry back out of the repo's own
    ///    `<repoRoot>/.mcp.json` (P4). FIRST, because it is the only step that
    ///    needs the repo path and the only one that touches a file the user can
    ///    see; and best-effort, because a repo that has been deleted or
    ///    unmounted must never strand a project in the registry. It never
    ///    deletes anything else in that file — see RepoMCPInstaller.
    var removeRepoEntry: @Sendable () async -> Void = {}
    /// 1. Sweep any LEGACY per-project database file left by a pre-P6 install
    ///    (.sqlite + -wal + -shm). Best-effort. MAY throw; the caller swallows.
    var deleteProjectDatabase: @Sendable (UUID) async throws -> Void
    /// 2. Release the security-scoped bookmark for the project's repo folder.
    ///    Best-effort. On a non-sandboxed build this is a no-op record drop.
    var releaseBookmark: @Sendable (UUID) async -> Void
    /// 3. Delete the global registry row (ProjectRecord + its repoBookmark
    ///    column). The FINAL act — the only step whose throw surfaces.
    var deleteRegistryRow: @Sendable (UUID) async throws -> Void
}

/// Runs the fixed-order, fault-tolerant deletion of one project.
nonisolated struct ProjectDeletion: Sendable {
    let steps: ProjectDeletionSteps

    /// Deletes the project. Steps 1–2 are best-effort; step 3 (registry row)
    /// runs last and rethrows on failure.
    func run(projectID: UUID) async throws {
        // 0. The repo's own .mcp.json entry — the one artifact of ours that
        //    lives INSIDE the user's repository. Removed first and best-effort.
        await steps.removeRepoEntry()

        // 1. Per-project DB file(s). A failure here (busy pool, missing file)
        //    must NOT strand the registry row — swallow and press on.
        do {
            try await steps.deleteProjectDatabase(projectID)
        } catch {
            deletionLogger.error("project DB delete failed for \(projectID, privacy: .public) — continuing to registry: \(String(describing: error), privacy: .public)")
        }

        // 2. Security-scoped bookmark.
        await steps.releaseBookmark(projectID)

        // 3. Registry row LAST — the decisive act. Its throw is the only one
        //    the caller sees; a retry re-runs every (idempotent) step.
        try await steps.deleteRegistryRow(projectID)
    }
}
