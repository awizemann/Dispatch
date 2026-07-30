---
title: Design Token Rulings and Theme Layer Decisions
type: note
permalink: dispatch/decisions/design-token-rulings-and-theme-layer-decisions
tags: [design, tokens, theme]
source_paths: [Dispatch/DesignSystem, Dispatch/Components/Chip.swift, Dispatch/App/ThemePersistence.swift]
source_paths_inferred: false
source_sha: 8d049fbc47ef9ff2f805acff08f21fc3d95f6ead
created: 2026-07-05
updated: 2026-07-13
reviewed: 2026-07-20
reviewed_by: audit:claude-code (background)
---

## Observations
- [decision] warningTint #F4E6D4 == amber agent tint is INTENTIONAL — amber = pending/issue is one design family; ship handoff hexes verbatim #tokens
- [decision] Agent colorIndex maps against AgentPalette.all = [indigo, slateBlue, amber, plum, rose] — that ordering (indigo first, not declaration order) is the persistence contract; never reorder #agents
- [decision] Shipping chrome/canvas swatches are the prototype props: outer #DFE0E5 #DEDFD8 #DCE1E6 #E2DEDA (L 74–96, default 88), canvas #E7E8EC #E7E8E2 #E4E9EE #EAE6E2 (L 80–98, default 92); resolved grey keeps swatch H+S and replaces L (HSL), mirroring the prototype _shade() #theme
- [decision] Scaffold deviations approved: Type→TypeScale with point-tracking TextStyle pairs, Shadows as View modifiers incl. modal/sheet, reduce-motion fallback for the 1.2s working-dots blink #designsystem
- [decision] Dark mode + Increase Contrast are out of scope for v1; named-token discipline is the future hook #scope
- [decision] (Phase 8, 2026-07-13) Outer-chrome and canvas colors are now LOCKED to spec constants (#181A21 / #E7E8EC) — swatch/lightness tunability, HSL shading path, and one-time Obsidian migration are all deleted; accent STAYS user-tunable (Theme pane = accent section only); rail widths remain user-preferences #theme

## Relations
- relates_to [[Design System and Accessibility Rules]]
