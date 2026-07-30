#!/bin/bash
# Build and launch a DETACHED dev copy of Dispatch.
#
# "Detached" means: built into its own isolated DerivedData (/tmp/dispatch-detached-dd)
# and launched from there, fully decoupled from any Xcode GUI build and from any
# "production" copy of Dispatch that may be managing real projects (we dogfood
# Dispatch on its own repo). Only the PREVIOUS detached instance is quit — matched by
# executable path, never by app name — so other running copies are untouched.
#
# The only Xcode on this machine is the Xcode 27 beta; DEVELOPER_DIR must be set explicitly.
#
# SIGNING: Debug signs with "Developer ID Application" (Manual, no provisioning profile)
# so the signature is stable across rebuilds — keychain ACL and TCC folder grants stick
# after the first approval. Do NOT revert to ad-hoc ("-"); see SIGNING.md.

set -euo pipefail

export DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="/tmp/dispatch-detached-dd"
APP_PATH="$DERIVED_DATA/Build/Products/Debug/Dispatch.app"
EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/Dispatch"

echo "==> Building Debug into $DERIVED_DATA"
xcodebuild \
    -project "$REPO_ROOT/Dispatch.xcodeproj" \
    -scheme Dispatch \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    -skipMacroValidation \
    build

if [[ ! -x "$EXECUTABLE_PATH" ]]; then
    echo "error: built app not found at $APP_PATH" >&2
    exit 1
fi

# Canonicalize: /tmp is a symlink to /private/tmp on macOS, and the running process
# reports the resolved path — match against that, or the quit-previous logic never fires.
EXECUTABLE_REAL="$(readlink -f "$EXECUTABLE_PATH")"

# Quit only our own previous detached instance (exact executable-path match).
PREVIOUS_PIDS="$(pgrep -f "^$EXECUTABLE_REAL" || true)"
if [[ -n "$PREVIOUS_PIDS" ]]; then
    echo "==> Quitting previous detached instance (pid(s): $PREVIOUS_PIDS)"
    kill $PREVIOUS_PIDS 2>/dev/null || true
    # Give it a moment to exit cleanly before relaunching.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -f "^$EXECUTABLE_REAL" > /dev/null || break
        sleep 0.3
    done
    pkill -9 -f "^$EXECUTABLE_REAL" 2>/dev/null || true
fi

echo "==> Launching detached dev copy: $APP_PATH"
open -n "$APP_PATH"
