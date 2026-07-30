---
title: Build Environment
type: note
permalink: dispatch/operations/build-environment
created: 2026-07-05
updated: 2026-07-05
tags:
- operations
- build
- toolchain
grounding: durable
---

Verified live at Phase 0 kickoff. Note: Swift 6.4 toolchain means swift-subprocess 1.0 (announced for the 6.4 wave) may already be releasable — the P0 dependency task should prefer 1.0 if tagged.

## Observations
- [fact] Dev machine (2026-07-05): macOS 27.0 beta (26A5368g), Xcode 27.0 beta ONLY (/Applications/Xcode-beta.app, 27A5209h), Swift 6.4 toolchain, Apple Git 2.54, Claude Code CLI 2.1.201 at ~/.local/bin/claude #environment
- [gotcha] xcode-select points at /Library/Developer/CommandLineTools, so bare `xcodebuild` fails — every build invocation and script must set DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer (avoids needing sudo xcode-select) #xcodeselect
- [convention] All CLI builds use a throwaway/isolated -derivedDataPath while the Xcode GUI may have the project open — same-build-system here (all Xcode 27 beta) but the isolation rule stands #deriveddata
- [fact] App deployment target stays macOS 26 (Tahoe) per the distribution decision, built with the Xcode 27 beta SDK; Swift 6 language mode with SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor #target

## Relations
- relates_to [[Build and Toolchain Rules]]
- relates_to [[Decision: Distribution and Platform Target]]
