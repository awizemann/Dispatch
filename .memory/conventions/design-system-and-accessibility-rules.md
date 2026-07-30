---
title: Design System and Accessibility Rules
type: note
permalink: dispatch/conventions/design-system-and-accessibility-rules
tags: [design, accessibility, standard]
created: 2026-07-05
updated: 2026-07-30
---
From kickoff standard §10 plus the design handoff. The design system covers TOKENS AND CHROME: dark graphite chrome (window backdrop + both rails, one continuous shell) framing a floating light center sheet (canvas, radius 16, white@8% ring, deep shadow) with white work surfaces (radius 14) floating on it; on-dark Chrome palette (text ramp + white-alpha surfaces + dark status variants) beside the light Ink/Surface/Status families; SF Pro Text / SF Mono split, agent tint palette (5 entries, unchanged), 120ms state / 220–320ms rise / 1.2s blink motion. High fidelity is required — recreate pixel-faithfully.

## Observations
- [convention] Single source for status→color; one chip component, not per-domain chip structs; all colors via DesignTokens — no raw Color(hex:) where a token exists #tokens
- [convention] Shared view helpers live in one Components layer — reuse, don't copy #reuse
- [convention] Every icon-only button gets .help + .accessibilityLabel AND a ~28–30pt padded hit frame with .contentShape(Rectangle()) #a11y
- [convention] Color-only signals get a text label or .accessibilityHidden(true) when sibling text carries the meaning; status chips pair text + color #a11y
- [fact] Only the ACCENT theme token is user-tunable (Settings → Theme, 5 curated swatches); outerChrome (#181A21) and canvas (#E7E8EC) are LOCKED spec constants since Phase 8 of the v3 redesign (Alan's ruling — supersedes the original three-tunables design). Rail widths are the other live theme preference #theme
