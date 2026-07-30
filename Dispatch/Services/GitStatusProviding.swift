// GitStatusProviding.swift
// The nonisolated protocol seam for git status reads (GitClient is the real
// implementation; MockGitStatus drives stores/tests). Declared `nonisolated
// protocol ...: Actor` so actor conformances work under
// SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor (see
// .memory/conventions/swift-6-2-concurrency-rules).

import Foundation

nonisolated protocol GitStatusProviding: Actor {
    /// True when `path` is inside a git work tree. Never throws — probe
    /// failures (missing binary, timeout) are logged and read as "not a repo".
    func isGitRepo(at path: String) async -> Bool

    /// The work-tree root containing `path` (`rev-parse --show-toplevel`).
    func repoRoot(for path: String) async throws -> String

    /// One status snapshot: branch, clean/dirty summary, unpushed count.
    func snapshot(at path: String) async throws -> GitSnapshot

    /// The `origin` remote's URL, or nil when there is no origin remote
    /// (feeds the GitHub owner/repo parser). Never throws for the
    /// "no remote" case; a genuine git failure still throws.
    func remoteURL(at path: String) async throws -> String?
}

// MARK: - Values

nonisolated struct GitSnapshot: Equatable, Sendable {
    var branch: BranchState
    var isClean: Bool
    /// Changed + renamed + unmerged + untracked entries (ignored excluded).
    var dirtyCount: Int
    var unpushed: UnpushedCount
}

nonisolated enum BranchState: Equatable, Sendable {
    case branch(String)
    case detached(shortSHA: String)

    /// What the projects-rail git row prints.
    var displayName: String {
        switch self {
        case .branch(let name): name
        case .detached(let sha): "detached @ \(sha)"
        }
    }
}

/// Unpushed commits ahead of `@{upstream}`. No-upstream and detached HEAD are
/// expected states, not errors — they render as "no pill" (design §1).
nonisolated enum UnpushedCount: Equatable, Sendable {
    case count(Int)
    case noUpstream
    case detached

    var displayCount: Int {
        if case .count(let n) = self { return n }
        return 0
    }
}

// MARK: - Error taxonomy

/// not-a-repo vs git-missing vs timeout vs plain failure — callers branch on
/// these (the modal shows a friendly inline error only for `.notARepository`).
nonisolated enum GitError: Error, Equatable {
    /// No usable git binary on PATH or at /usr/bin/git.
    case gitBinaryNotFound
    /// The directory is not inside a git work tree (exit 128).
    case notARepository(path: String)
    /// The subprocess exceeded its explicit deadline and was torn down.
    case timeout(operation: String)
    /// git exited non-zero (or died on a signal) for another reason.
    case execFailed(operation: String, exitCode: Int32, stderrExcerpt: String)
    /// A destructive verb (reset/clean/move) was pointed outside the whitelisted
    /// app-owned area — refused structurally (guardrail §4). Dispatch runs no
    /// destructive git verb today; the guard stays as the structural floor.
    case pathNotWhitelisted(path: String)
}
