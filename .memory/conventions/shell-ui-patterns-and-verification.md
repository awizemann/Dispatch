---
title: Shell UI Patterns and Verification
type: note
permalink: dispatch/conventions/shell-ui-patterns-and-verification
tags: [swiftui, shell, verification, patterns]
source_paths: [Dispatch/App/ThemePersistence.swift, Dispatch/DesignSystem/Theme.swift, Dispatch/Views/ProjectsRail/ProjectCardView.swift, Dispatch/Views/ProjectsRail/ProjectsRailView.swift, Dispatch/Stores/Mocks]
source_paths_inferred: false
source_sha: e24495a2b7b67f6aed88344545a31286318bdd6b
created: 2026-07-05
updated: 2026-07-18
reviewed: 2026-07-30
reviewed_by: human
---

Learned building the P0 app shell (Views/, Stores/, 2026-07-05). Also of note: project card tints are currently derived from the name's first scalar (Project DTO has no persisted tint field) — reproduces the prototype exactly today, but a persisted tint may be wanted when project creation UX matures.

## Observations
- [convention] RETIRED (Obsidian v3, 2026-07-13, branch redesign/obsidian-v3): the punched-in / connected-selection technique (UnevenRoundedRectangle square trailing corners bridging into the neighbor) is gone everywhere — v3 selection = solid white card + entity-color border@50% + 3px inset left spine (Metrics.agentSpine) + tinted glow (reference impl: AgentCardView; docs list mirrors it). The docked-slot UnevenRoundedRectangle survives ONLY as QueuePanelChrome for genuinely in-chat strips (QA validation queue, crew proposal). The verification rule stands: check seams/fidelity with pixel sampling, never eyeballs #technique
- [convention] Mock seam pattern: actor fakes over the PersistenceReading protocols with initial-emission-then-yields broadcast exactly mimic GRDB ValueObservation, making store observation loops testable with pollUntil on MainActor #mocks
- [gotcha] Headless UI verification limit: CGEvent/AppleScript synthetic clicks silently no-op without Accessibility permission — verify interactions via store tests + a human click pass; capture windows via screencapture -l <CGWindowID> #verification
- [gotcha] SF Mono 9.5 rows in the 236pt projects rail are width-critical: the git row fits only with spacing ≤6 and .fixedSize() on the unpushed pill #layout
- [done] RESOLVED: the default-lightness fidelity drift is FIXED — each swatch's default lightness now derives from the swatch hex's OWN HSL L (ThemePersistence outer/canvas defaults 88.627 / 91.569, i.e. #DFE0E5 / #E7E8EC verbatim), so at default slider positions resolved chrome/canvas equal the spec swatch (was #E8E9ED / #DDDEE3 vs spec #E7E8EC / #DFE0E5, ±1–2 RGB points) #theme

- [gotcha] Second-instance verification launches: exec'ing the app binary directly while another Dispatch instance is running yields a process with NO window (main thread parks at the entry point) — launch via `open -n <app> --args --mock-scenario` through Launch Services instead, and match windows by PID (not owner name: Alan's live instance will match first). Full recipe: .claude/skills/verify/SKILL.md #verification
