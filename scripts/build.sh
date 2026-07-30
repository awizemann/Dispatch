#!/bin/bash
# Plain CLI build + test for Dispatch.
#
# The only Xcode on this machine is the Xcode 27 beta at /Applications/Xcode-beta.app;
# xcode-select points at CommandLineTools, so DEVELOPER_DIR must always be set explicitly.
# Uses an isolated DerivedData so it never shares build state with the Xcode GUI.
#
# SIGNING: all configs sign with "Developer ID Application" (team 3Q6X2L86C4, Manual —
# no provisioning profile needed, so CLI builds stay network-free). Debug keeps hardened
# runtime OFF (debuggable); Release has it ON for notarization. Do NOT revert
# Debug to ad-hoc ("-"): an ad-hoc signature changes every rebuild, which resets keychain
# item ACLs and TCC folder grants — the app re-prompts on every launch. See SIGNING.md.

set -euo pipefail

export DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="/tmp/dispatch-ci-dd"

# Release compile check FIRST: #Preview bodies are type-checked in Release, so an
# un-gated reference to a #if DEBUG-only seam breaks ONLY Release and stays
# invisible until notarization. No tests — the shared scheme builds DispatchTests
# in Debug only. Runs before the Debug suite so it fails fast and still executes
# when a suite flake would red the run later. Same DerivedData: the mixing gotcha is
# about two build SYSTEMS on one DerivedData, not two configurations — sharing
# keeps SwiftPM resolution warm, so this step is incremental after the first run.
xcodebuild \
    -project "$REPO_ROOT/Dispatch.xcodeproj" \
    -scheme Dispatch \
    -destination 'platform=macOS' \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    -skipMacroValidation \
    build

# -skipMacroValidation: lets CLI builds proceed when a package ships a Swift macro
# (Xcode's macro-trust approval is interactive and would otherwise fail the build).
xcodebuild \
    -project "$REPO_ROOT/Dispatch.xcodeproj" \
    -scheme Dispatch \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    -skipMacroValidation \
    build test "$@"
