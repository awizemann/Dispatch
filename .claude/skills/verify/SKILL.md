---
name: verify
description: Build, launch, and visually verify Dispatch UI changes via the mock scenario — safe (no persistence, no live bus traffic), headless-capture friendly.
---

# Verifying Dispatch UI changes

## Build
```bash
xcodebuild -scheme Dispatch -configuration Debug -destination 'platform=macOS,arch=arm64' -quiet build
APP=$(xcodebuild -scheme Dispatch -configuration Debug -destination 'platform=macOS,arch=arm64' -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{print $2; exit}')/Dispatch.app
```

## Launch — ALWAYS the mock scenario, ALWAYS via `open -n -F`
```bash
open -n -F "$APP" --args --mock-scenario          # scripted switchboard, never persists
```
`-F` (fresh: ignore saved application state) is **load-bearing**. Without it a
previous run's `~/Library/Saved Application State/com.wizemann.dispatch.savedState`
can make the app launch with **no window at all** — the process runs, the main
thread parks in the run loop, and nothing appears. If a launch produces no
window, delete that directory and relaunch with `-F`.

Other gotchas:
- **Never verify against a live instance.** Alan may have a real Dispatch
  running. Match windows by **PID / window id**, not owner name.
- **Exec'ing the binary directly creates no window** (process runs, main thread
  parked at entry). `open -n ... --args` through Launch Services works.
- Live boot (no `--mock-scenario`) opens the developer's real DB and binds the
  real bus port — never launch that way for verification.

### DEBUG launch flags (states you cannot click your way to)
Synthetic clicks are forbidden (CGEvent/AppleScript no-op without Accessibility
permission), so these put the app straight into a state. All DEBUG-only and
inert in Release — see `Dispatch/Support/LaunchState.swift`.

| Flag | Effect |
|---|---|
| `--expand-messages` | every question card starts expanded (answer block + pending action row) |
| `--status=Pending\|Answered\|Expired\|Closed\|All` | boots the inbox on that status pill |
| `--settings=General\|Theme\|Notifications` | opens the Settings modal on that pane (⌘, is a key event) |
| `--mock-empty` | the same mock with NO projects: first-run welcome + every empty state |
| `--tab=Messages` | opens directly on a tab |

## Capture (per conventions/shell-ui-patterns-and-verification)
No synthetic clicks. Interactions: store tests + a human click pass. Visuals:
```bash
# window id for YOUR pid:
swift -e 'import CoreGraphics; let l = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String:Any]]; for w in l where (w["kCGWindowOwnerName"] as? String) == "Dispatch" { print(w["kCGWindowOwnerPID"]!, w["kCGWindowNumber"]!, w["kCGWindowIsOnscreen"] ?? false) }'
caffeinate -u -t 4 & sleep 3          # a SLEEPING display captures pure black
screencapture -x -l <windowID> out.png
sips --cropOffset <y> <x> -c <h> <w> out.png --out crop.png   # zoom a region
```
Controls render in their **inactive** appearance when the session is locked
(switches lose their accent fill) — that is a capture artifact, not a bug.
Kill only the PID you launched when done.

## Mock scenario map (`Dispatch/Stores/Mocks/MockData.swift`)
Three projects, chosen to show the whole state space at once:
- **Ledgerline** — pinned, selected, LIVE on the bus, linked to Driftwood,
  3 unpushed commits, `.mcp.json` installed.
- **Driftwood** — linked to Ledgerline, live, on `feature/sync-worker`,
  installed. Carries the amber attention badge (pending inbound).
- **Halyard** — **unlinked**, never connected, `bus not installed`: the
  "unfinished setup" card, and what `ask_agent` fails closed against.

Seven questions cover every card state: answered-by-a-project,
answered-by-the-human (arbitration), pending inbound, pending outbound, one
pending **near expiry** (amber countdown), expired, and human-closed.

**Live long poll:** `--mock-scenario` (app launch only, not previews or tests)
answers the `qLivePoll` question ~6s after launch through the same observation
stream the real database drives. A screenshot before then shows it pending;
after, answered with a fresh ticker line. `MockData.makeStores(live:)` defaults
to `false` so previews and store tests stay deterministic.

Bus listener status is **scripted** in the mock (`127.0.0.1:51872`, 2 of 3 repos
installed); `refreshBusStatus()` no-ops without a router so the footer's poll
cannot stomp it.
