// GitClient.swift
// The real GitStatusProviding: shells out to the git executable via
// swift-subprocess (decision: dispatch/decisions/decision-git-github-and-process-layer
// — no libgit2 bindings; porcelain formats are the stable API).
//
// Binary resolution (approved 2026-07-05): scan PATH for an executable `git`
// (respects Homebrew installs), fall back to /usr/bin/git (the xcrun shim →
// CommandLineTools git on this machine — fine at runtime; the Xcode-beta
// DEVELOPER_DIR is a build-script concern and never set in the app process).
// The first candidate that answers `--version` is cached for the actor's life.
//
// Every subprocess call: explicit timeout (task-group race; cancellation drives
// swift-subprocess's SIGTERM→SIGKILL teardown), captured stderr in errors,
// os.Logger on failure (paths logged .private per error-handling rules).

import Foundation
import os
import Subprocess
import System

private nonisolated let logger = Logger(subsystem: "com.wizemann.dispatch", category: "git")

actor GitClient: GitStatusProviding {

    /// Per-command deadline. git status on large repos is sub-second; 10s only
    /// trips on wedged filesystems (network volumes, dead FUSE mounts).
    private let timeout: Duration
    private var cachedGitPath: FilePath?

    init(timeout: Duration = .seconds(10)) {
        self.timeout = timeout
    }

    // MARK: - GitStatusProviding

    func isGitRepo(at path: String) async -> Bool {
        do {
            let result = try await runGit(
                ["rev-parse", "--is-inside-work-tree"],
                in: path, operation: "rev-parse --is-inside-work-tree"
            )
            return result.exitCode == 0
                && result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        } catch {
            // Probe semantics: any failure (no binary, timeout, missing dir)
            // reads as "not a repo"; the cause is logged for diagnosis.
            logger.warning("isGitRepo probe failed at \(path, privacy: .private): \(String(describing: error), privacy: .public)")
            return false
        }
    }

    func repoRoot(for path: String) async throws -> String {
        let operation = "rev-parse --show-toplevel"
        let result = try await runGit(["rev-parse", "--show-toplevel"], in: path, operation: operation)
        guard result.exitCode == 0 else {
            throw Self.failure(result, operation: operation, path: path)
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func snapshot(at path: String) async throws -> GitSnapshot {
        let operation = "status --porcelain=v2 --branch"
        let result = try await runGit(
            ["status", "--porcelain=v2", "--branch"],
            in: path, operation: operation
        )
        guard result.exitCode == 0 else {
            throw Self.failure(result, operation: operation, path: path)
        }
        let parsed = GitPorcelainParser.parse(result.stdout)

        let branch: BranchState
        if parsed.isDetached {
            branch = .detached(shortSHA: await shortHEAD(at: path))
        } else {
            branch = .branch(parsed.branchHead ?? "unknown")
        }

        let unpushed = try await unpushedCount(at: path, parsed: parsed)

        // branch.ab is the cross-check; rev-list is the source (approved plan).
        if let ahead = parsed.ahead, case .count(let counted) = unpushed, ahead != counted {
            logger.warning("git ahead-count mismatch: branch.ab \(ahead) vs rev-list \(counted)")
        }

        return GitSnapshot(
            branch: branch,
            isClean: parsed.isClean,
            dirtyCount: parsed.dirtyCount,
            unpushed: unpushed
        )
    }

    // MARK: - Unpushed commits

    private func unpushedCount(at path: String, parsed: GitPorcelainParser.Status) async throws -> UnpushedCount {
        if parsed.isDetached { return .detached }
        // Unborn branch or no upstream configured: nothing to count, no spawn.
        if parsed.isUnborn || parsed.upstream == nil { return .noUpstream }

        let operation = "rev-list --count @{upstream}..HEAD"
        let result = try await runGit(
            ["rev-list", "--count", "@{upstream}..HEAD"],
            in: path, operation: operation
        )
        if result.exitCode == 0,
           let count = Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return .count(count)
        }
        // Upstream listed by status but the count failed — e.g. the remote
        // branch was deleted. Classify the expected shapes; escalate the rest.
        if let classified = Self.classifyRevListFailure(stderr: result.stderr) {
            logger.warning("rev-list fell back to \(String(describing: classified), privacy: .public) at \(path, privacy: .private)")
            return classified
        }
        throw Self.failure(result, operation: operation, path: path)
    }

    /// Maps rev-list stderr to the graceful UnpushedCount states. Internal
    /// (not private) so the mapping is unit-testable without spawning git.
    /// Subprocess env pins LC_ALL=C, so these English messages are stable.
    nonisolated static func classifyRevListFailure(stderr: String) -> UnpushedCount? {
        let message = stderr.lowercased()
        if message.contains("head does not point to a branch") {
            return .detached
        }
        if message.contains("no upstream configured")
            || message.contains("does not have an upstream")
            || message.contains("unknown revision")
            || message.contains("ambiguous argument") {
            return .noUpstream
        }
        return nil
    }

    private func shortHEAD(at path: String) async -> String {
        let result = try? await runGit(
            ["rev-parse", "--short", "HEAD"],
            in: path, operation: "rev-parse --short HEAD"
        )
        guard let result, result.exitCode == 0 else { return "unknown" }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Remote URL

    /// The `origin` remote URL via `git remote get-url origin`. A repo with no
    /// origin remote is an expected, non-error state → nil (git exits 128 with
    /// "No such remote"). Any other failure throws through the taxonomy. This is
    /// a pure read (whitelisted like the other status verbs); the parsed
    /// owner/repo drives the GitHub PR/issue counts.
    func remoteURL(at path: String) async throws -> String? {
        let operation = "remote get-url origin"
        let result = try await runGit(
            ["remote", "get-url", "origin"], in: path, operation: operation
        )
        if result.exitCode == 0 {
            let url = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return url.isEmpty ? nil : url
        }
        // No origin remote configured — git reports this on exit 128/2 with a
        // "No such remote" message. Read it as "no remote", not a failure.
        if result.stderr.lowercased().contains("no such remote") {
            return nil
        }
        throw Self.failure(result, operation: operation, path: path)
    }

    // MARK: - Subprocess plumbing

    /// Nested in the actor, so explicitly nonisolated (actor statics/nested
    /// types default to MainActor under this project's default isolation).
    private nonisolated struct CommandResult: Sendable {
        var exitCode: Int32
        var stdout: String
        var stderr: String
    }

    private func runGit(
        _ arguments: [String], in directory: String?, operation: String,
        outputLimit: Int = 4 * 1024 * 1024, timeoutOverride: Duration? = nil,
        indexFile: String? = nil
    ) async throws -> CommandResult {
        let git = try await gitExecutable()
        return try await execute(
            git, arguments: arguments, in: directory, operation: operation,
            outputLimit: outputLimit, timeoutOverride: timeoutOverride,
            indexFile: indexFile
        )
    }

    private func execute(
        _ executable: FilePath, arguments: [String], in directory: String?, operation: String,
        outputLimit: Int = 4 * 1024 * 1024, timeoutOverride: Duration? = nil,
        indexFile: String? = nil
    ) async throws -> CommandResult {
        let timeout = timeoutOverride ?? timeout
        // LC_ALL=C pins the stderr messages classifyRevListFailure matches;
        // GIT_TERMINAL_PROMPT=0 turns would-be credential prompts into fast
        // failures; optional locks off so status never contends with a running
        // agent's git. indexFile points git at a scratch index (GIT_INDEX_FILE)
        // for the 3-way merge so the real index/worktree are never touched.
        let environment: Environment = {
            let base = Environment.inherit.updating([
                "LC_ALL": "C",
                "GIT_TERMINAL_PROMPT": "0",
                "GIT_OPTIONAL_LOCKS": "0",
            ])
            guard let indexFile else { return base }
            return base.updating(["GIT_INDEX_FILE": indexFile])
        }()
        do {
            return try await withThrowingTaskGroup(of: CommandResult?.self) { group in
                group.addTask {
                    let result = try await Subprocess.run(
                        .path(executable),
                        arguments: Arguments(arguments),
                        environment: environment,
                        workingDirectory: directory.map { FilePath($0) },
                        output: .string(limit: outputLimit),
                        error: .string(limit: 256 * 1024)
                    )
                    let exitCode: Int32 = switch result.terminationStatus {
                    case .exited(let code): code
                    case .signaled: -1
                    }
                    return CommandResult(
                        exitCode: exitCode,
                        stdout: result.standardOutput ?? "",
                        stderr: result.standardError ?? ""
                    )
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    return nil // the deadline lost the race only if this never returns first
                }
                // Group-exit cancellation tears the child process down
                // (swift-subprocess: SIGTERM → SIGKILL).
                defer { group.cancelAll() }
                guard let first = try await group.next(), let result = first else {
                    logger.warning("git \(operation, privacy: .public) timed out after \(String(describing: timeout), privacy: .public)")
                    throw GitError.timeout(operation: operation)
                }
                return result
            }
        } catch let error as GitError {
            throw error
        } catch is CancellationError {
            // Caller (e.g. a refresh loop) was cancelled — propagate, don't log.
            throw CancellationError()
        } catch {
            // Spawn failures (missing working directory, exec errors) land here.
            logger.error("git \(operation, privacy: .public) failed to run: \(String(describing: error), privacy: .public)")
            throw GitError.execFailed(operation: operation, exitCode: -1, stderrExcerpt: String(describing: error))
        }
    }

    /// Maps a non-zero CommandResult to the error taxonomy and logs it.
    private nonisolated static func failure(_ result: CommandResult, operation: String, path: String) -> GitError {
        let excerpt = String(result.stderr.prefix(500)).trimmingCharacters(in: .whitespacesAndNewlines)
        if result.exitCode == 128, excerpt.lowercased().contains("not a git repository") {
            logger.warning("git \(operation, privacy: .public): not a repository at \(path, privacy: .private)")
            return .notARepository(path: path)
        }
        logger.error("git \(operation, privacy: .public) exited \(result.exitCode): \(excerpt, privacy: .public)")
        return .execFailed(operation: operation, exitCode: result.exitCode, stderrExcerpt: excerpt)
    }

    // MARK: - Binary resolution

    private func gitExecutable() async throws -> FilePath {
        if let cachedGitPath { return cachedGitPath }
        for candidate in Self.candidatePaths() {
            let probe = try? await execute(
                FilePath(candidate), arguments: ["--version"],
                in: nil, operation: "--version"
            )
            if let probe, probe.exitCode == 0 {
                logger.info("git resolved to \(candidate, privacy: .public) (\(probe.stdout.trimmingCharacters(in: .whitespacesAndNewlines), privacy: .public))")
                let path = FilePath(candidate)
                cachedGitPath = path
                return path
            }
        }
        logger.error("no usable git binary found on PATH or at /usr/bin/git")
        throw GitError.gitBinaryNotFound
    }

    private nonisolated static func candidatePaths() -> [String] {
        var candidates: [String] = []
        let pathValue = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for entry in pathValue.split(separator: ":") where !entry.isEmpty {
            let candidate = "\(entry)/git"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                candidates.append(candidate)
            }
        }
        if !candidates.contains("/usr/bin/git") {
            candidates.append("/usr/bin/git")
        }
        return candidates
    }
}
