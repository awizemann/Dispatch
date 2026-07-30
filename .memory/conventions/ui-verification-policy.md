---
title: UI Verification Policy
type: note
permalink: dispatch/conventions/ui-verification-policy
tags: [testing, verification, policy]
created: 2026-07-05
updated: 2026-07-30
---
## Observations
- [constraint] NEVER drive Alan's real session: no global-HID event synthesis, nothing that moves the real pointer, steals focus, foregrounds an app, or can reach any app other than the app-under-test #policy
- [constraint] The policy is strict: no global HID synthesis, no AX driving of Alan's real session, ever — Dispatch has no in-app agent runtime to drive a built app-under-test with, so there is no carve-out to narrow #policy
- [convention] Interaction verification ladder: (1) store/unit tests for all interaction logic, (2) milestone human click-pass — give Alan a short numbered checklist + reference screenshots + a running detached dev copy, (3) XCUITest smoke target as an optional Phase 4 addition (drives only the app under test, no global permission) #ladder
- [convention] Visual verification stays headless: screencapture -l <CGWindowID> for window captures, pixel sampling for seams/colors — no screen-recording permissions needed for the app's own windows #screenshots
- [fact] P0 shell click pass completed by Alan 2026-07-05 — card selection, pin/unpin, MCP popover + Fix, triage dismiss/expand all verified working #history

**Field additions (P2):** `screencapture -l` fails with "could not create image from window" when the display is asleep — run `caffeinate -u -t 8` first. DEBUG launch args available for headless verification: `--mock-scenario` (scripted fixture data), `--mock-autoplay` (drives store paths), `--tab=<name>` (direct tab capture). Also: `.task(id:)` consuming a route request must fold the selected project into its Equatable id, or cross-project routes don't re-fire.
