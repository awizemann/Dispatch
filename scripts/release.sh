#!/usr/bin/env bash

# --- Xcode toolchain guard: build with a real Xcode.app (not the Command Line Tools),
#     resolved via DEVELOPER_DIR (no sudo). This machine's only Xcode is the 27 beta,
#     and xcode-select points at CommandLineTools, so we must set it explicitly. ---
if [ -z "${DEVELOPER_DIR:-}" ]; then
  case "$(xcode-select -p 2>/dev/null)" in
    */Xcode*.app/Contents/Developer) : ;;
    *) for _xc in /Applications/Xcode-beta.app /Applications/Xcode.app /Applications/Xcode-*.app; do
         [ -x "$_xc/Contents/Developer/usr/bin/xcodebuild" ] && { export DEVELOPER_DIR="$_xc/Contents/Developer"; break; }
       done ;;
  esac
fi
#
# Dispatch release pipeline — local, manual, repeatable.
#
# Usage:
#   ./scripts/release.sh 1.0.0              # full release: build, sign, notarize,
#                                           # GitHub release, tag main
#   ./scripts/release.sh 1.0.0 --draft      # everything builds + notarizes, but the
#                                           # GitHub release is created as draft and
#                                           # main is NOT tagged/pushed. Promote manually.
#
# Release notes (optional):
#   If `releases/v<VERSION>/RELEASE_NOTES.md` exists, it becomes the GitHub
#   release body and the commit summary. If not, the script falls back to a
#   generic note — so you can just run the script. Write notes ahead of time for
#   a real changelog.
#
# Prerequisites (one-time setup):
#   1. Developer ID Application cert installed in the login Keychain.
#        security find-identity -v -p codesigning | grep "Developer ID Application"
#      (Dispatch signs as: Alan Wizemann (3Q6X2L86C4) — see scripts/SIGNING.md.)
#   2. A notarytool keychain profile for your Apple Developer account (Team
#      3Q6X2L86C4). Defaults to the shared "harness-notary" profile — the same
#      credential the Harness/Scarf releases use — so no new setup is needed.
#      Use a different one with:  DISPATCH_NOTARY_PROFILE=<name> ./release.sh 1.0.0
#      (To create a fresh one:  xcrun notarytool store-credentials <name> \
#         --key ~/.private/AuthKey_XXXX.p8 --key-id <KEY_ID> --issuer <ISSUER_ID>)
#   3. gh CLI authed with write access to awizemann/Dispatch:
#        gh auth status
#
# Notes on Dispatch vs. Harness/Scarf: Dispatch has no xcodegen/project.yml (the
# version lives in Dispatch.xcodeproj/project.pbxproj) and ships no Sparkle
# auto-update, so there is no appcast step. Distribution is Developer ID + notarized,
# non-sandboxed (see scripts/SIGNING.md). The .app is exported universal.

set -euo pipefail

# ---------- arg parsing ----------
VERSION=""
DRAFT=0
for arg in "$@"; do
  case "$arg" in
    --draft) DRAFT=1 ;;
    -h|--help)
      cat >&2 <<'USAGE'
Dispatch release pipeline — build, sign, notarize, package, and publish a GitHub release.

  ./scripts/release.sh 1.0.0            full release: bump version, archive, notarize,
                                        tag + push main, create the GitHub release
  ./scripts/release.sh 1.0.0 --draft    build + notarize, create a DRAFT release,
                                        do NOT tag or push main (promote manually)

Requires (see the header of this script for setup):
  - "Developer ID Application" cert in the login Keychain (team 3Q6X2L86C4)
  - notarytool profile (defaults to shared "harness-notary"; override with DISPATCH_NOTARY_PROFILE)
  - gh authenticated with write access to awizemann/Dispatch
  - (optional) releases/v<VERSION>/RELEASE_NOTES.md for a real changelog
    (without it the release gets a generic note)
USAGE
      exit 0 ;;
    -*) printf '[ERR] unknown flag: %s\n' "$arg" >&2; exit 1 ;;
    *) [[ -z "$VERSION" ]] && VERSION="$arg" || { printf '[ERR] unexpected arg: %s\n' "$arg" >&2; exit 1; } ;;
  esac
done
[[ -n "$VERSION" ]] || { printf 'usage: ./scripts/release.sh <marketing-version> [--draft]\n' >&2; exit 1; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { printf '[ERR] version must be X.Y.Z (got: %s)\n' "$VERSION" >&2; exit 1; }

# ---------- config ----------
TEAM_ID="3Q6X2L86C4"
BUNDLE_ID="com.wizemann.dispatch"
SCHEME="Dispatch"
PROJECT="Dispatch.xcodeproj"
PBXPROJ="Dispatch.xcodeproj/project.pbxproj"
NOTARY_PROFILE="${DISPATCH_NOTARY_PROFILE:-harness-notary}"
SIGNING_IDENTITY="Developer ID Application"
GH_REPO="awizemann/Dispatch"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build"
ARCHIVE_PATH="$BUILD_DIR/Dispatch.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
EXPORT_OPTIONS="$REPO_ROOT/scripts/ExportOptions.plist"
RELEASE_DIR="$REPO_ROOT/releases/v${VERSION}"
ZIP_NAME="Dispatch-v${VERSION}-Universal.zip"
ZIP_PATH="$RELEASE_DIR/$ZIP_NAME"

# ---------- helpers ----------
log()  { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[WARN] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERR] %s\033[0m\n' "$*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }

# ---------- preflight ----------
log "Preflight checks"
require_cmd git
require_cmd xcodebuild
require_cmd xcrun
require_cmd ditto
require_cmd gh
require_cmd python3

cd "$REPO_ROOT"

[[ -f "$EXPORT_OPTIONS" ]] || die "missing $EXPORT_OPTIONS"
[[ -f "$PBXPROJ" ]] || die "missing $PBXPROJ (run from the Dispatch repo)"

# Git must be clean and on main. Allow releases/v<VERSION> to be untracked (the
# RELEASE_NOTES.md prep flow) — git status abbreviates a fully-untracked dir to
# its trailing slash, so whitelist all three observable forms.
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[[ "$BRANCH" == "main" ]] || die "must be on 'main' (currently '$BRANCH')"

# Memophant keeps its managed tiers + regenerated config files perpetually dirty;
# none affect the app binary, and the release commit stages ONLY the version bump
# + notes explicitly (never `git add -A`), so dirty managed files can't leak into
# the release. Exclude them — and releases/v<VERSION>/ — from the clean-tree gate.
MANAGED='(\.memory/|wiki/|design/|documents/|tasks/|sessions/|code/|vendors/|templates/|TASKS\.md|AGENTS\.md|GEMINI\.md|\.mcp\.json|\.cursor/|\.codex/|\.gemini/|\.claude/|\.github/copilot-instructions\.md)'
DIRTY="$(git status --porcelain \
  | grep -vE "^\?\? releases/" \
  | grep -vE "^..[[:space:]]${MANAGED}" \
  || true)"
[[ -z "$DIRTY" ]] || die "git tree has uncommitted changes outside the Memophant-managed files and releases/v${VERSION}/. Commit or stash them, then re-run:
$DIRTY"

# Release notes are optional (see header). If the file exists it's used as the
# release body + commit summary; otherwise the script falls back to a generic note.
NOTES_PATH="$RELEASE_DIR/RELEASE_NOTES.md"

# Tag must not already exist.
if git rev-parse "v${VERSION}" >/dev/null 2>&1; then
  die "tag 'v${VERSION}' already exists. Bump the version or delete the tag."
fi

# Codesign identity present.
security find-identity -v -p codesigning | grep -q "$SIGNING_IDENTITY" \
  || die "no '$SIGNING_IDENTITY' identity in login Keychain. See header for setup."

# Notary profile present (no listing API; test with a cheap history call).
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" --output-format plist >/dev/null 2>&1 \
  || die "notarytool profile '$NOTARY_PROFILE' missing or invalid. See header for setup, or set DISPATCH_NOTARY_PROFILE."

# gh authed.
gh auth status >/dev/null 2>&1 || die "'gh' is not authenticated. Run 'gh auth login'."

# gh always prefers $GITHUB_TOKEN over its keyring; if that token lacks write scope
# the release 403s AFTER the whole build+notarize cycle. Warn + verify up front.
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  warn "GITHUB_TOKEN is set — gh will use it instead of its keyring."
  warn "  If it lacks 'repo' (classic) / 'Contents: Write' (fine-grained), the release will 403 after the build."
  warn "  Recovery: 'unset GITHUB_TOKEN' to fall back to the keyring, or rotate the token."
fi

log "Checking gh has write access to ${GH_REPO}"
PUSH_OK="$(gh api "/repos/${GH_REPO}" --jq '.permissions.push' 2>/dev/null || echo "false")"
[[ "$PUSH_OK" == "true" ]] || die "gh's active token has no write access to ${GH_REPO}. Releases would 403 after the build.
  Recovery: unset GITHUB_TOKEN, then 'gh auth login' with 'repo' scope, confirm 'gh auth status', re-run."

log "Preflight OK"

# ---------- bump version in project.pbxproj ----------
# MARKETING_VERSION drives CFBundleShortVersionString (the user-facing version).
# CURRENT_PROJECT_VERSION is the build number (CFBundleVersion) — bump it monotonically
# as release hygiene (Dispatch has no Sparkle, so nothing depends on it today, but
# Gatekeeper/update semantics still prefer an increasing build number). Both keys
# appear once per build config (app + tests, Debug + Release); set every occurrence
# so the app and its test host stay consistent.
log "Setting MARKETING_VERSION to $VERSION and bumping CURRENT_PROJECT_VERSION in $PBXPROJ"
python3 - "$PBXPROJ" "$VERSION" <<'PY'
import re, sys, pathlib
path, version = pathlib.Path(sys.argv[1]), sys.argv[2]
text = path.read_text()

new, n = re.subn(r'(MARKETING_VERSION = )[0-9][0-9.A-Za-z\-]*(;)', rf'\g<1>{version}\g<2>', text)
if n == 0:
    raise SystemExit("MARKETING_VERSION line not found in project.pbxproj")

# Increment every CURRENT_PROJECT_VERSION to the same next integer (max + 1).
builds = [int(m) for m in re.findall(r'CURRENT_PROJECT_VERSION = (\d+);', new)]
if not builds:
    raise SystemExit("CURRENT_PROJECT_VERSION line not found in project.pbxproj")
nextb = max(builds) + 1
new = re.sub(r'(CURRENT_PROJECT_VERSION = )\d+(;)', rf'\g<1>{nextb}\g<2>', new)

if new != text:
    path.write_text(new)
PY

# ---------- bump the README version badge ----------
# README hero shows a shields.io version badge. Anchored patterns so unrelated
# digits-with-dots can't match; dies if a pattern stops matching (badge changed).
log "Updating README.md version badge"
python3 - "$REPO_ROOT/README.md" "$VERSION" <<'PY'
import re, sys, pathlib
path, version = pathlib.Path(sys.argv[1]), sys.argv[2]
text = path.read_text()
patterns = [
    (r'(\[Version: )\d+\.\d+\.\d+(\])', rf'\g<1>{version}\g<2>'),          # ![Version: X.Y.Z]
    (r'(version-)\d+\.\d+\.\d+(-blue)', rf'\g<1>{version}\g<2>'),          # shields URL version-X.Y.Z-blue
]
new, missing = text, []
for pat, repl in patterns:
    new, n = re.subn(pat, repl, new)
    if n == 0:
        missing.append(pat)
if missing:
    raise SystemExit("README.md: version-badge pattern(s) not found — hero may have changed:\n  " + "\n  ".join(missing))
if new != text:
    path.write_text(new)
PY

# Stage the version bump (committed alongside the release notes below).
git add "$PBXPROJ" README.md

# ---------- archive ----------
log "Cleaning build directory"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

log "Archiving (Release, universal)"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  -skipMacroValidation \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Manual \
  archive

# ---------- export ----------
log "Exporting (.app)"
mkdir -p "$EXPORT_DIR"
xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS"

APP_PATH="$EXPORT_DIR/${SCHEME}.app"
[[ -d "$APP_PATH" ]] || die "exported .app not found at $APP_PATH"

# Guard the generated Info.plist: a broken Xcode plist merge could drop the
# version/icon keys and ship a versionless or iconless app. Fail loudly here.
PLIST="$APP_PATH/Contents/Info.plist"
for key in CFBundleShortVersionString CFBundleVersion CFBundleIdentifier; do
  /usr/libexec/PlistBuddy -c "Print :$key" "$PLIST" >/dev/null 2>&1 \
    || die "built Info.plist missing '$key' — the plist merge may have broken."
done
GOT_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")"
[[ "$GOT_VERSION" == "$VERSION" ]] || die "built app version is '$GOT_VERSION', expected '$VERSION' — version bump didn't take."
GOT_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$PLIST")"
[[ "$GOT_ID" == "$BUNDLE_ID" ]] || die "built app bundle id is '$GOT_ID', expected '$BUNDLE_ID'."
[[ -f "$APP_PATH/Contents/Resources/AppIcon.icns" ]] || warn "AppIcon.icns not found in the built app — the release will ship without an icon file."

# Confirm the export is Developer-ID signed with hardened runtime (notarization posture).
log "Verifying code signature"
codesign -dvvv "$APP_PATH" 2>&1 | grep -q "Authority=Developer ID Application" \
  || die "exported app is not Developer ID signed."
codesign --verify --strict --verbose=2 "$APP_PATH" 2>&1 | sed 's/^/    /'

# ---------- notarize ----------
log "Zipping for notarization"
NOTARIZE_ZIP="$BUILD_DIR/Dispatch-notarize.zip"
ditto -c -k --keepParent "$APP_PATH" "$NOTARIZE_ZIP"

log "Submitting to notarytool (this can take a few minutes)"
xcrun notarytool submit "$NOTARIZE_ZIP" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

log "Stapling ticket to .app"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH" >/dev/null

# ---------- final zip ----------
log "Packaging $ZIP_NAME"
mkdir -p "$RELEASE_DIR"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

# Sanity-check the Gatekeeper assessment on the stapled app.
log "spctl --assess (should print 'accepted')"
spctl --assess --type execute --verbose=2 "$APP_PATH" 2>&1 | sed 's/^/    /'

# ---------- commit + tag ----------
log "Staging version bump + release notes"
[[ -f "$NOTES_PATH" ]] && git add "$NOTES_PATH"
# Skip the release commit when there's nothing staged — happens when the notes +
# version bump were committed ahead of running the script. Tag the tip instead.
if git diff --cached --quiet; then
  log "Nothing to commit (notes + version already on main) — tagging tip"
else
  SUMMARY="Dispatch v${VERSION}"
  [[ -f "$NOTES_PATH" ]] && SUMMARY="$(head -1 "$NOTES_PATH" | sed 's/^#* *//')"
  git commit -m "release: v${VERSION}

${SUMMARY}"
fi

if [[ "$DRAFT" -eq 1 ]]; then
  warn "draft mode — skipping tag + push of main"
else
  log "Tagging v${VERSION}"
  git tag -a "v${VERSION}" -m "Dispatch v${VERSION}"
  log "Pushing main + tag"
  git push origin main
  git push origin "v${VERSION}"
fi

# ---------- gh release ----------
RELEASE_FLAGS=(--title "Dispatch v${VERSION}")
if [[ -f "$NOTES_PATH" ]]; then
  RELEASE_FLAGS+=(--notes-file "$NOTES_PATH")
else
  RELEASE_FLAGS+=(--notes "Dispatch v${VERSION}. See the commit history for details.")
fi
[[ "$DRAFT" -eq 1 ]] && RELEASE_FLAGS+=(--draft)

log "Creating GitHub release"
if [[ "$DRAFT" -eq 1 ]]; then
  gh release create "v${VERSION}" "$ZIP_PATH" "${RELEASE_FLAGS[@]}" || die "gh release create failed"
else
  gh release create "v${VERSION}" "$ZIP_PATH" "${RELEASE_FLAGS[@]}" --target main || die "gh release create failed"
fi

log "Done."
log "Artifact: $ZIP_PATH"
if [[ "$DRAFT" -eq 1 ]]; then
  log "Draft release created. Promote at: https://github.com/${GH_REPO}/releases"
else
  log "Live: https://github.com/${GH_REPO}/releases/tag/v${VERSION}"
fi
