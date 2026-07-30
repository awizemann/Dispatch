---
title: Bus Map UI Conventions
type: note
permalink: dispatch/conventions/bus-map-ui-conventions
source_paths: [Dispatch/Views/BusMap]
source_paths_inferred: false
source_sha: 773387c86eee060e6d47db6e231db0763e659f56
created: 2026-07-30
updated: 2026-07-30
---

BusMapView draws the switchboard itself: stations are projects, lines are projectLink rows that let two projects talk, and a travelling dot runs the line each time a question or answer actually crosses it. It must never disagree with the projects rail — same selection state, two views of it.

## Observations
- [convention] A station answers four questions matching the rail card exactly: WHO (tinted initial tile + name), REACHABLE (filled/blinking dot when that repo's session is live on the bus, hollow ring when not), SET UP (amber ring when the repo's .mcp.json has no live dispatch entry — same amber/meaning as the card chip), IN SCOPE (an unlinked project is dimmed and sits apart) #parity
- [convention] Clicking a station selects that project in the rail — one shared selection state, never a second independent one #selection
- [constraint] No drag, no zoom — the map is a status surface, not a canvas; a graph the user can shove around stops being a reliable reference #scope
- [convention] Every signal is color-or-position AND spoken: a station announces name + connection + links + pending count, each link line is its own element announcing "X linked to Y"; travelling-dot pulses are decorative (the ticker already says what happened in words) so they're accessibility-hidden, and Reduce Motion swaps the dot for a brief line highlight #a11y

## Relations
- relates_to [[Design System and Accessibility Rules]]
