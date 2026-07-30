---
title: Window Frame Persistence and Watchdog Heuristic Rulings
type: note
permalink: dispatch/conventions/window-frame-persistence-and-watchdog-heuristic-rulings
tags: [window, watchdog, gotcha, conventions]
source_paths: [Dispatch/App/WindowFrameAutosave.swift]
source_paths_inferred: false
source_sha: 2e02e96100cf0a74f8c46fde34723901e828595a
created: 2026-07-13
updated: 2026-07-30
reviewed: 2026-07-30
reviewed_by: audit:claude-code (background)
---
Durable outcome from dogfood round 1b (2026-07-13, commit 1d4a3fb), replacing an approach that failed in the field twice. The watchdog half of this note was struck 2026-07-29: stuck-agent detection belonged to an earlier in-app agent runtime that Dispatch does not have.

## Observations
- [gotcha] NSWindow frameAutosaveName CANNOT be made authoritative from an NSViewRepresentable in a SwiftUI WindowGroup: window resizes fire no scene update, so updateNSView never runs at save time and SwiftUI's own (type-signature-keyed, churning) autosave name wins every save — evidence: 56 orphaned WindowGroup frame keys all storing exactly the defaultSize #window
- [convention] Window frame persistence is SELF-OWNED: didMove/didResize observers write `DispatchWindowFrame.<name>` in UserDefaults; launch restores it clamped to a visible screen AFTER the window attaches; frameAutosaveName is never touched (App/WindowFrameAutosave.swift) #window

## Relations
- relates_to [[SwiftUI View Discipline]]
