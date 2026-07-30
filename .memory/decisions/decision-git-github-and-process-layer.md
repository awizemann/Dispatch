---
title: Decision: Git GitHub and Process Layer
type: note
permalink: dispatch/decisions/decision-git-github-and-process-layer
tags: [decision, git, github, subprocess]
source_paths: [Dispatch/Services/GitClient.swift, Dispatch.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved]
source_paths_inferred: false
source_sha: a71c2b9eeb17dacf71380d0688ea097252aad6be
created: 2026-07-05
updated: 2026-07-29
reviewed: 2026-07-23
reviewed_by: audit:claude-code (background)
---

Decided 2026-07-05 from infrastructure research. SwiftGitX (modern libgit2 wrapper, pre-1.0) stays on the watchlist if in-process status polling ever becomes a perf need.

## Observations
- [decision] Git layer shells out to the git executable via swiftlang/swift-subprocess (AsyncSequence stdout, structured cancellation, SIGTERM→SIGKILL teardown) behind a GitClient actor parsing --porcelain=v2 / --numstat — no libgit2 bindings #git
- [decision] STRUCK by the Dispatch pivot (2026-07-28): the GitHub URLSession/PAT client and the native gitleaks-seeded secret scanner are both gone — they served issue import and the commit gate, neither of which exists. Dispatch's git surface is read-only status for the project cards #struck
- [gotcha] swift-subprocess is pre-1.0 (v0.5); Subprocess 1.0 lands with Swift 6.4 — pin the version and plan a small migration; PTY not needed for headless stream-json agents (SwiftTerm only if we ever embed a terminal pane) #pinning
- [fact] WHY shell-out over libgit2: GitKraken publicly migrated off libgit2 to the executable; SwiftGit2 is stale (2019 release); porcelain formats are stable API; agents already exec git themselves so the runtime dependency exists anyway #rationale
