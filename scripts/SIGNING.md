# Code Signing

## Current state (landed 2026-07-08)

All configurations of both targets sign with the real **Developer ID** identity:

```
CODE_SIGN_IDENTITY = "Developer ID Application";   // resolves to: Alan Wizemann (3Q6X2L86C4)
CODE_SIGN_STYLE = Manual;
DEVELOPMENT_TEAM = 3Q6X2L86C4;
```

- **Debug** (app + tests): hardened runtime **OFF** so the debugger can attach
  (Xcode injects `get-task-allow` into Debug signatures).
- **Release** (app): hardened runtime **ON** — the notarization posture.
  (A signing-unrelated Release compile break from un-gated `#if DEBUG`-only
  preview helpers is fixed; `build.sh` now runs a Release compile check first
  so the class can't ship silently.)

Developer ID signing needs **no provisioning profile**, so `scripts/build.sh` and
`scripts/build-detached.sh` sign cleanly from the CLI with no network dependency.
Verified: `./scripts/build.sh` (build + full test suite) green;
`codesign -dvvv` on both the CI and detached apps shows
`Authority=Developer ID Application: Alan Wizemann (3Q6X2L86C4)`.

## Why this matters (the bug it fixed)

Debug builds used to be **ad-hoc** signed (`CODE_SIGN_IDENTITY = "-"`). An ad-hoc
signature is a fresh, unique signature on every rebuild, and macOS keys two kinds of
grants on the app's code signature (its *designated requirement*):

1. **Keychain item ACLs** — each stored credential prompts "allow access?" per item;
   "Always Allow" records the current signature, which the next rebuild no longer matches.
   With several stored credentials that meant a prompt storm on every launch.
   (Dispatch stores no Keychain credentials today — the bus token is a per-repo
   config value that lives in the database and in the repo's own `.mcp.json` —
   but the TCC grants below still make signature stability worth keeping.)
2. **TCC folder grants** (Documents, etc.) — same mechanism, so folder access
   re-prompted every rebuild.

With the Developer ID identity the designated requirement is certificate-anchored and
identical across rebuilds, so both grant types persist after the first approval.

**Do not revert Debug to ad-hoc** — the prompt storm comes straight back.

## What does NOT work (tried, documented for posterity)

The Xcode-managed **Apple Development** cert (team TN755TG4M3) hard-fails Manual CLI
signing (`No signing certificate "Mac Development" found ...`); it only signs through
`CODE_SIGN_STYLE = Automatic` + `-allowProvisioningUpdates`, which would make the build
gate depend on the network and Apple's provisioning service. Not acceptable.

An earlier draft of this doc proposed a self-signed "Dispatch Dev" certificate as a
workaround; that is superseded — the Developer ID identity is stable *and* the real
commercial signing identity.

## Remaining for distribution

Signing identity and hardened runtime are already in place for Release. Still open:

- Notarization (`notarytool submit` + staple) in a distribution script.
- Decide sandbox posture: App Sandbox + real security-scoped bookmarks
  (`RepoBookmark.swift` rework + `com.apple.security.files.user-selected.read-write`
  entitlement) is required only for Mac App Store; Developer ID distribution can stay
  non-sandboxed. Note Dispatch WRITES into each linked repo (`.mcp.json`), so the
  sandboxed path needs a live security-scoped session for every linked folder.

## Dependencies

Dispatch links five SwiftPM packages: GRDB, the MCP swift-sdk, swift-nio (the bus
listener's HTTP server), swift-subprocess (git), and Defaults. All are versioned
remote packages — there is no path dependency, so a Release build IS reproducible
from a commit.
