#!/bin/bash
# Test, build, sign, notarize, staple, and package the macOS app.
# This script never prints credentials. Notarization uses an App Store Connect
# API key when ASC_KEY_ID, ASC_ISSUER_ID and ASC_PRIVATE_KEY_PATH are set (CI),
# otherwise APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD and APPLE_TEAM_ID from
# ~/.zshrc.
#
#   scripts/release.sh
#   SKIP_TESTS=1 scripts/release.sh
#
# The iPhone app has its own script: scripts/release-ios.sh.
# See docs/RELEASING.md.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" && -f "${ASC_PRIVATE_KEY_PATH:-}" ]]; then
  notary_auth=(--key "$ASC_PRIVATE_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
else
  for variable in APPLE_ID APPLE_APP_SPECIFIC_PASSWORD APPLE_TEAM_ID; do
    if [[ -z "${!variable:-}" ]]; then
      echo "error: $variable is unset; source ~/.zshrc before running this script." >&2
      exit 1
    fi
  done
  notary_auth=(--apple-id "$APPLE_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --team-id "$APPLE_TEAM_ID")
fi

# The Mac mini keeps the Developer ID key in its own keychain, unlocked with a
# password file only the release user can read (scripts/setup-mac-signing.sh).
signing_keychain="$HOME/Library/Keychains/voiceiq-signing.keychain-db"
if [[ -f "$signing_keychain" && -f "$HOME/.voiceiq-signing/keychain.pass" ]]; then
  security unlock-keychain -p "$(cat "$HOME/.voiceiq-signing/keychain.pass")" "$signing_keychain"
fi
# Output is captured before matching: with pipefail, `grep -q` exiting early
# can make the pipeline fail even when it matched.
[[ "$(security find-identity -v -p codesigning)" == *"Developer ID Application: "*"(G8K3545FJ2)"* ]] || {
  echo "error: no Developer ID Application identity; run scripts/setup-mac-signing.sh (docs/RELEASING.md)" >&2
  exit 1
}

VERSION=$(awk '/MARKETING_VERSION:/ {gsub(/"/, "", $2); print $2; exit}' project.yml)
BUILD_DIR="build/release"
DERIVED_DATA="$BUILD_DIR/DerivedData"
APP_NAME="VoiceiQ"
APP_PATH="$DERIVED_DATA/Build/Products/Release/$APP_NAME.app"
ZIP_PATH="$BUILD_DIR/VoiceiQ-$VERSION.zip"
DMG_PATH="$BUILD_DIR/VoiceiQ-$VERSION.dmg"
SIGN_IDENTITY="Developer ID Application"

if [[ -z "${SKIP_TESTS:-}" ]]; then
  echo "▸ Testing VoiceIQCore"
  scripts/test.sh
fi

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "▸ Generating project"
xcodegen generate

echo "▸ Building Developer ID Release"
env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all \
  xcodebuild build \
    -project VoiceIQ.xcodeproj \
    -scheme VoiceIQ \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
    DEVELOPMENT_TEAM=G8K3545FJ2 \
    ENABLE_HARDENED_RUNTIME=YES \
    OTHER_CODE_SIGN_FLAGS=--timestamp \
    -quiet

[[ -d "$APP_PATH" ]] || { echo "error: build produced no app at $APP_PATH" >&2; exit 1; }

python3 scripts/check-app-bundle.py "$APP_PATH"

echo "▸ Verifying app signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign -dvv "$APP_PATH"
if [[ "$(codesign -d --entitlements :- "$APP_PATH" 2>/dev/null)" == *get-task-allow* ]]; then
  echo "error: get-task-allow is present in the Release app." >&2
  exit 1
fi
SPARKLE="$APP_PATH/Contents/Frameworks/Sparkle.framework"
for helper in "$SPARKLE/Versions/B/Autoupdate" "$SPARKLE/Versions/B/Updater.app" "$SPARKLE"; do
  [[ "$(codesign -dv "$helper" 2>&1)" == *"TeamIdentifier=G8K3545FJ2"* ]] || {
    echo "error: $helper is not signed with the Developer ID (scripts/sign-sparkle.sh)." >&2
    exit 1
  }
done

echo "▸ Notarizing app"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
xcrun notarytool submit "$ZIP_PATH" \
  "${notary_auth[@]}" \
  --wait
xcrun stapler staple "$APP_PATH"
spctl -a -t exec -vv "$APP_PATH"
# Re-zip after stapling so the zip is shareable on its own: Gatekeeper on an
# offline Mac reads the stapled ticket instead of asking Apple.
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

echo "▸ Building and signing DMG"
APP_NAME="$APP_NAME" scripts/make-dmg.sh "$APP_PATH" "$DMG_PATH"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"

echo "▸ Notarizing DMG"
xcrun notarytool submit "$DMG_PATH" \
  "${notary_auth[@]}" \
  --wait
xcrun stapler staple "$DMG_PATH"
spctl -a -t open --context context:primary-signature -vv "$DMG_PATH"

echo "✓ $DMG_PATH"
echo "  Publish with scripts/publish-github-release.sh (docs/UPDATES.md)."
