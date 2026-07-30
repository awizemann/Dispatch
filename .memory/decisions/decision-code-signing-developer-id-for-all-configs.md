---
title: Decision: Code Signing — Developer ID for all configs
type: note
permalink: dispatch/decisions/decision-code-signing-developer-id-for-all-configs
created: 2026-07-08
updated: 2026-07-20
---

Decided 2026-07-08. Full write-up: `scripts/SIGNING.md`.

## Observations
- [decision] All configs of both targets sign with `CODE_SIGN_IDENTITY = "Developer ID Application"` (Alan Wizemann, team 3Q6X2L86C4), `CODE_SIGN_STYLE = Manual`, `DEVELOPMENT_TEAM = 3Q6X2L86C4`. Developer ID needs no provisioning profile, so CLI builds (`scripts/build.sh`, `scripts/build-detached.sh`) sign with zero network dependency. #signing
- [why] Debug was previously ad-hoc (`"-"`): a fresh signature every rebuild reset keychain item ACLs (one prompt per stored credential — UsageKeychainStore, KeychainPATStore, MemophantPairing) and TCC folder grants (Documents re-prompt) on every launch. Stable Developer ID signature → grants stick after first approval. It was never an entitlements problem: app is non-sandboxed, no kSecAttrAccessGroup usage, no .entitlements file needed for the dev loop. #keychain #tcc
- [gotcha] Do NOT revert Debug to ad-hoc — prompt storm returns. Do NOT try the Apple Development cert (team TN755TG4M3) with Manual style: it hard-fails CLI signing and only works via Automatic + -allowProvisioningUpdates (network-dependent, rejected). #gotcha
- [fact] Debug keeps ENABLE_HARDENED_RUNTIME=NO (debugger/get-task-allow); Release now has YES — the Phase 5 notarization posture. Release config compile break (preview helpers not #if DEBUG-gated at call sites) was fixed 2026-07-20 — Release now builds clean, so the hardened-runtime posture is actually exercisable. #phase5

## Relations
- relates_to [[Build Environment]]
- relates_to [[Build and Toolchain Rules]]
- relates_to [[Decision: Distribution and Platform Target]]
