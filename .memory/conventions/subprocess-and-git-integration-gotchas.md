---
title: Subprocess and Git Integration Gotchas
type: note
permalink: dispatch/conventions/subprocess-and-git-integration-gotchas
tags: [subprocess, git, gotcha]
source_paths: [Dispatch/Services/GitClient.swift, Dispatch/Services/RepoBookmark.swift]
source_paths_inferred: false
source_sha: 2e02e96100cf0a74f8c46fde34723901e828595a
created: 2026-07-05
updated: 2026-07-30
reviewed: 2026-07-30
reviewed_by: audit:claude-code (background)
---

Learned building the P0 GitClient + project flow (2026-07-05). CancellationError must propagate from subprocess exec helpers rather than being mapped into execFailed noise.

## Observations
- [gotcha] swift-subprocess 0.5 on macOS: `import System` (its canImport(System) path, not SystemPackage); Subprocess.run(.path(FilePath), output: .string(limit:)); NO built-in timeout — race in a task group, cancellation drives its SIGTERM→SIGKILL teardown; unconsumed child errors are discarded on group return #subprocess
- [gotcha] Pin LC_ALL=C on any subprocess whose stderr you classify (git localizes fatal messages); also set GIT_TERMINAL_PROMPT=0 and GIT_OPTIONAL_LOCKS=0 for background git #environment
- [gotcha] .withSecurityScope bookmark creation THROWS without the sandbox entitlement — non-sandboxed builds use plain bookmarks; keep start/stopAccessing wrapped (RepoBookmark) so a future sandbox flip is one-line #bookmarks
- [fact] Porcelain v2 --branch gives upstream presence for free — skip the rev-list spawn entirely when branch.upstream is absent/unborn/detached #optimization
- [gotcha] The memophant-mcp binary falls through to MCP SERVER MODE on any unknown subcommand (`recent`, `--help`, pre-`search` builds given `search`) and hangs FOREVER even with stdin closed — confirmed on two surfaces (shell probe + provider spawn). Any one-shot invocation of it MUST race a hard timeout and reap the child; never assume unknown-verb → error-exit #subprocess #memophant
- [convention] Async form-validation outcomes are path-guarded (only apply if the input that started validation is still current) — MainActor serialization usually suffices but the guard makes correctness locally provable in audit #forms

## Relations
- relates_to [[Decision: Git GitHub and Process Layer]]
- relates_to [[Swift 6.2 Concurrency Rules]]
