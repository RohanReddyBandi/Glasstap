#!/usr/bin/env bash
#
# Builds a signed, notarized, stapled Glasstap DMG, ready to attach to a GitHub Release.
#
#   scripts/release.sh 0.2.0          # full release → dist/Glasstap-0.2.0.dmg
#   scripts/release.sh 0.2.0 --dry-run # sign with your development cert, skip notarization
#
# Signing uses the "Developer ID Application" certificate in your keychain. Notarization
# credentials come from, in order:
#   1. App Store Connect API key:  NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER_ID
#   2. Apple ID:                   APPLE_ID, APPLE_APP_PASSWORD (an app-specific password)
#   3. A saved keychain profile:   NOTARY_PROFILE (default "glasstap-notary"), created once with
#        xcrun notarytool store-credentials glasstap-notary --apple-id YOU --team-id B5526BNTDG
#
# See docs/RELEASING.md for the one-time setup.

set -euo pipefail

VERSION="${1:-}"
DRY_RUN=false
[[ "${2:-}" == "--dry-run" || "${1:-}" == "--dry-run" ]] && DRY_RUN=true
[[ "$VERSION" == "--dry-run" ]] && VERSION=""

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TEAM_ID="${TEAM_ID:-B5526BNTDG}"
SCHEME="Glasstap"
APP_NAME="Glasstap"
BUILD_DIR="$ROOT/build/release"
DIST_DIR="$ROOT/dist"
ARCHIVE="$BUILD_DIR/$APP_NAME.xcarchive"

if $DRY_RUN; then
  SIGN_IDENTITY="${SIGN_IDENTITY:-Apple Development}"
else
  SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
fi

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
fail() { printf '\n\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
step "Checking tools and certificates"

command -v xcodebuild >/dev/null || fail "Xcode command-line tools not found."
if [[ -z "$VERSION" ]]; then
  VERSION=$(xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$SCHEME" -configuration Release -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ MARKETING_VERSION = /{print $2; exit}')
fi
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || fail "Version must look like 1.2.3 (got '$VERSION')."
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

if ! security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY"; then
  fail "No '$SIGN_IDENTITY' certificate in your keychain. See docs/RELEASING.md, step 1."
fi

NOTARY_ARGS=()
if ! $DRY_RUN; then
  if [[ -n "${NOTARY_KEY_ID:-}" ]]; then
    [[ -f "${NOTARY_KEY_PATH:-}" ]] || fail "NOTARY_KEY_PATH must point at your AuthKey_XXXX.p8 file."
    NOTARY_ARGS=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "${NOTARY_ISSUER_ID:?NOTARY_ISSUER_ID is required with NOTARY_KEY_ID}")
  elif [[ -n "${APPLE_ID:-}" ]]; then
    NOTARY_ARGS=(--apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "${APPLE_APP_PASSWORD:?APPLE_APP_PASSWORD is required with APPLE_ID}")
  else
    NOTARY_ARGS=(--keychain-profile "${NOTARY_PROFILE:-glasstap-notary}")
  fi
fi

echo "Version $VERSION (build $BUILD_NUMBER), signing as '$SIGN_IDENTITY'$($DRY_RUN && echo ', dry run: no notarization')"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$DIST_DIR"

# ---------------------------------------------------------------------------
step "Archiving"

xcodebuild archive \
  -project "$APP_NAME.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE" \
  -destination "generic/platform=macOS" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  > "$BUILD_DIR/archive.log" 2>&1 \
  || { grep -E "error:" "$BUILD_DIR/archive.log" | head -20; tail -15 "$BUILD_DIR/archive.log"; fail "Archive failed. Full log: build/release/archive.log"; }
echo "Archived (log: build/release/archive.log)"

APP="$BUILD_DIR/$APP_NAME.app"
[[ -d "$ARCHIVE/Products/Applications/$APP_NAME.app" ]] || fail "Archive failed; no app in $ARCHIVE."
ditto "$ARCHIVE/Products/Applications/$APP_NAME.app" "$APP"

# ---------------------------------------------------------------------------
step "Verifying the signature"

codesign --verify --deep --strict --verbose=2 "$APP"
SIGN_INFO=$(codesign -dvv "$APP" 2>&1)
echo "$SIGN_INFO" | grep -E "^(Authority|TeamIdentifier|Timestamp|Runtime)" || true
echo "$SIGN_INFO" | grep -q "flags=.*runtime" || fail "Hardened Runtime is off; notarization would reject this build."
if codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q "get-task-allow"; then
  fail "The build has the debugging entitlement (get-task-allow); notarization would reject it."
fi
echo "Entitlements:"
codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -p - || true

# ---------------------------------------------------------------------------
notarize() {
  local file="$1"
  step "Notarizing $(basename "$file") (usually 1-5 minutes)"
  local output
  if ! output=$(xcrun notarytool submit "$file" "${NOTARY_ARGS[@]}" --wait --output-format json 2>&1); then
    echo "$output"
    fail "Notarization request failed. Check your credentials (docs/RELEASING.md, step 2)."
  fi
  echo "$output"
  local status id
  status=$(echo "$output" | plutil -extract status raw - 2>/dev/null || echo "")
  id=$(echo "$output" | plutil -extract id raw - 2>/dev/null || echo "")
  if [[ "$status" != "Accepted" ]]; then
    [[ -n "$id" ]] && xcrun notarytool log "$id" "${NOTARY_ARGS[@]}" || true
    fail "Apple did not accept $(basename "$file") (status: ${status:-unknown}). The log above says why."
  fi
}

if ! $DRY_RUN; then
  # Notarize and staple the app itself first, so it opens without a network check even
  # after it's been dragged out of the DMG.
  ZIP="$BUILD_DIR/$APP_NAME.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  notarize "$ZIP"
  step "Stapling the app"
  xcrun stapler staple "$APP"
fi

# ---------------------------------------------------------------------------
step "Building the DMG"

DMG="$DIST_DIR/$APP_NAME-$VERSION.dmg"
rm -f "$DMG"
STAGING="$BUILD_DIR/dmg"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/$APP_NAME.app"

plain_dmg() {
  ln -sfn /Applications "$STAGING/Applications"
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO -fs HFS+ "$DMG" >/dev/null
}

if command -v create-dmg >/dev/null; then
  # Drag-to-Applications window with the app and the Applications folder side by side.
  # create-dmg arranges the window by scripting Finder, which occasionally times out on CI
  # machines; fall back to a plain DMG (same contents, default layout) if it does.
  create-dmg \
    --volname "$APP_NAME" \
    --window-pos 200 160 \
    --window-size 560 340 \
    --icon-size 112 \
    --icon "$APP_NAME.app" 150 160 \
    --app-drop-link 410 160 \
    --hide-extension "$APP_NAME.app" \
    --no-internet-enable \
    "$DMG" "$STAGING" \
    || { echo "create-dmg failed; building a plain DMG instead."; rm -f "$DMG"; plain_dmg; }
else
  echo "create-dmg not installed (brew install create-dmg for a nicer window); using hdiutil."
  plain_dmg
fi

codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG"

if ! $DRY_RUN; then
  notarize "$DMG"
  step "Stapling the DMG"
  xcrun stapler staple "$DMG"

  step "Gatekeeper check"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
  spctl --assess --type execute --verbose=2 "$APP"
fi

# ---------------------------------------------------------------------------
step "Done"
SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')
echo "$DMG"
echo "SHA-256: $SHA"
if $DRY_RUN; then
  echo "Dry run: signed with '$SIGN_IDENTITY' and not notarized. Don't publish this one."
else
  echo "Publish it with:  gh release create v$VERSION \"$DMG\" --title \"Glasstap $VERSION\" --generate-notes"
fi
