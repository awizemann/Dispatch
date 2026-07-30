// MockGitStatus.swift
// Actor fake for GitStatusProviding — scripted per-path snapshots so the mock
// composition and tests exercise the store's refresh/validation paths without
// spawning git. Swapped for GitClient in AppStores.live().

import Foundation

actor MockGitStatus: GitStatusProviding {

    /// Paths that read as git repos. Empty set + `allPathsAreRepos` covers the
    /// common "everything is a repo" scripting.
    private var repoPaths: Set<String>
    private let allPathsAreRepos: Bool
    /// Scripted snapshots keyed by path; `defaultSnapshot` otherwise.
    private var snapshots: [String: GitSnapshot]
    private let defaultSnapshot: GitSnapshot
    /// Scripted origin remote URLs keyed by path; nil (no origin) otherwise.
    private var remoteURLs: [String: String]
    /// When set, repoRoot/snapshot throw this (isGitRepo reads it as false).
    private var scriptedError: GitError?

    init(
        allPathsAreRepos: Bool = true,
        repoPaths: Set<String> = [],
        snapshots: [String: GitSnapshot] = [:],
        remoteURLs: [String: String] = [:],
        defaultSnapshot: GitSnapshot = GitSnapshot(
            branch: .branch("main"), isClean: true, dirtyCount: 0, unpushed: .count(0)
        )
    ) {
        self.allPathsAreRepos = allPathsAreRepos
        self.repoPaths = repoPaths
        self.snapshots = snapshots
        self.remoteURLs = remoteURLs
        self.defaultSnapshot = defaultSnapshot
    }

    // MARK: - Scripting

    func setError(_ error: GitError?) {
        scriptedError = error
    }

    func setSnapshot(_ snapshot: GitSnapshot, for path: String) {
        snapshots[path] = snapshot
    }

    func setRemoteURL(_ url: String?, for path: String) {
        remoteURLs[path] = url
    }

    // MARK: - GitStatusProviding

    func isGitRepo(at path: String) async -> Bool {
        guard scriptedError == nil else { return false }
        return allPathsAreRepos || repoPaths.contains(path)
    }

    func repoRoot(for path: String) async throws -> String {
        if let scriptedError { throw scriptedError }
        guard allPathsAreRepos || repoPaths.contains(path) else {
            throw GitError.notARepository(path: path)
        }
        return path
    }

    func snapshot(at path: String) async throws -> GitSnapshot {
        if let scriptedError { throw scriptedError }
        guard allPathsAreRepos || repoPaths.contains(path) else {
            throw GitError.notARepository(path: path)
        }
        return snapshots[path] ?? defaultSnapshot
    }

    func remoteURL(at path: String) async throws -> String? {
        if let scriptedError { throw scriptedError }
        return remoteURLs[path]
    }
}
