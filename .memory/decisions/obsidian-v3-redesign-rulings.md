---
title: Obsidian v3 Redesign Rulings
type: note
permalink: dispatch/decisions/obsidian-v3-redesign-rulings
tags: [design, obsidian-v3, redesign, rulings]
source_paths: [Dispatch/DesignSystem, Dispatch/Components/RailResizeHandle.swift, Dispatch/Views/ProjectsRail]
source_paths_inferred: false
source_sha: 5806824c6bf9f806d26d1aefcd714792d65891fa
created: 2026-07-13
updated: 2026-07-29
reviewed: 2026-07-26
reviewed_by: audit:claude-code (background)
---
The Obsidian v3 shell rulings, trimmed 2026-07-29 to the ones Dispatch still ships (the work-queue card, review-rail badge and top-bar token readout rulings went with the features).

## Observations
- [decision] Rails are TRANSPARENT over one continuous window gradient (resolved outerChrome → Chrome.backdropDeep) — no per-rail fills, no seams; the center sheet clips BEFORE sheetChrome() #shell
- [decision] Surface.well is THE recessed-element token on light surfaces: use it over Surface.codeBlock for command wells inside light modals (no lone dark islands) and NEVER use theme.canvas as an inner-card fill #tokens
- [decision] Settings entry is the standard macOS path: CommandGroup(replacing: .appSettings) ⌘, sets the settings route — there is no rail gear #chrome
- [decision] (Phase 8, 2026-07-13) Chrome/canvas theming is REMOVED: outerChrome (#181A21) and canvas (#E7E8EC) are locked `let` constants on Theme; swatch/lightness state, HSL shading path, migration and contrast clamp are deleted; accent STAYS tunable #theme
- [decision] Projects rail top = two rows: Row 1 traffic-lights-only drag strip (Metrics.titleBarHeight 30pt), Row 2 full-width brand row above PROJECTS #chrome

## Relations
- relates_to [[Design Token Rulings and Theme Layer Decisions]]
- relates_to [[Design System and Accessibility Rules]]
- relates_to [[Shell UI Patterns and Verification]]
