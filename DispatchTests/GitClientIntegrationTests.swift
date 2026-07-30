// GitClientIntegrationTests.swift
// The ONE test-for-real: a real temp git repo (git init, commit) exercised
// through the real GitClient end-to-end — binary resolution, subprocess
// plumbing, porcelain parsing, unpushed classification, detached HEAD.
// Everything else about the parser is fixture-tested without spawning git.

import Foundation
import Testing
@testable import DispatchApp

@Suite("GitClient integration (real temp repo)", .serialized)
struct GitClientIntegrationTests {

    @Test("End-to-end against a real repo: probe, unborn, clean, dirty, root, detached")
    func realTempRepoEndToEnd() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("dispatch-git-it-\(UUID().uuidString)", isDirectory: true)
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        let plain = root.appendingPathComponent("plain", isDirectory: true)
        try fileManager.createDirectory(at: repo, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: plain, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let client = GitClient()

        // Not a repo yet: probe is false, repoRoot throws .notARepository.
        let preProbe = await client.isGitRepo(at: plain.path)
        #expect(preProbe == false)
        await #expect(throws: GitError.notARepository(path: plain.path)) {
            _ = try await client.repoRoot(for: plain.path)
        }

        // Unborn branch: init without a commit → branch named, no upstream.
        try runGit(["init", "-b", "main"], in: repo)
        let unborn = try await client.snapshot(at: repo.path)
        #expect(unborn.branch == .branch("main"))
        #expect(unborn.unpushed == .noUpstream)

        // First commit → clean snapshot.
        try runGit(["-c", "user.email=test@dispatch.local", "-c", "user.name=Dispatch Tests",
                    "commit", "--allow-empty", "-m", "init"], in: repo)
        let probe = await client.isGitRepo(at: repo.path)
        #expect(probe == true)
        let clean = try await client.snapshot(at: repo.path)
        #expect(clean.branch == .branch("main"))
        #expect(clean.isClean)
        #expect(clean.dirtyCount == 0)
        #expect(clean.unpushed == .noUpstream) // no remote → graceful, not an error

        // Untracked file → dirty.
        try "hello".write(to: repo.appendingPathComponent("file.txt"),
                          atomically: true, encoding: .utf8)
        let dirty = try await client.snapshot(at: repo.path)
        #expect(!dirty.isClean)
        #expect(dirty.dirtyCount == 1)

        // repoRoot resolves from a subdirectory to the repo root
        // (symlink-normalized: /tmp vs /private/tmp).
        let sub = repo.appendingPathComponent("sub", isDirectory: true)
        try fileManager.createDirectory(at: sub, withIntermediateDirectories: true)
        let reportedRoot = try await client.repoRoot(for: sub.path)
        #expect(URL(fileURLWithPath: reportedRoot).resolvingSymlinksInPath().path
                == repo.resolvingSymlinksInPath().path)

        // Detached HEAD → detached branch state + graceful unpushed.
        try runGit(["checkout", "--detach"], in: repo)
        let detached = try await client.snapshot(at: repo.path)
        guard case .detached(let sha) = detached.branch else {
            Issue.record("expected detached HEAD, got \(detached.branch)")
            return
        }
        #expect(!sha.isEmpty && sha != "unknown")
        #expect(detached.unpushed == .detached)
    }

    // MARK: - Repo arrangement helper (test-only; the code under test never
    // uses Process)

    private func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.executableLoad, userInfo: [
                NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) exited \(process.terminationStatus)"
            ])
        }
    }
}
