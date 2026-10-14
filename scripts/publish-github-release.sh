#!/bin/bash
# Publishes the notarized build from scripts/release.sh as a GitHub Release,
# together with the Sparkle appcast that installed copies read to update.
#
#   scripts/publish-github-release.sh            # create the release
#   DRY_RUN=1 scripts/publish-github-release.sh  # build and verify the appcast only
#
# Needs gh signed in with push access, release notes, and the Sparkle EdDSA
# private key: login keychain account "voiceiq", or a key file exported from it
# in SPARKLE_ED_KEY_FILE. RELEASE_NOTES is the GitHub release body and
# SPARKLE_NOTES the text in the update alert (Markdown); both default to
# release-notes/<version>.md. CI writes them with scripts/generate-release-notes.py.
# See docs/UPDATES.md.
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD_DIR="build/release"
APP_PATH="$BUILD_DIR/DerivedData/Build/Products/Release/VoiceiQ.app"
SPARKLE_BIN="$BUILD_DIR/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"
STAGE="$BUILD_DIR/appcast"

fail() { echo "error: $*" >&2; exit 1; }

[[ -d "$APP_PATH" ]] || fail "no Release app at $APP_PATH; run scripts/release.sh first."
[[ -x "$SPARKLE_BIN/generate_appcast" ]] || fail "Sparkle tools missing at $SPARKLE_BIN; run scripts/release.sh first."
command -v gh >/dev/null || fail "gh is not installed (brew install gh)."

plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP_PATH/Contents/Info.plist"; }
VERSION=$(plist CFBundleShortVersionString)
BUILD=$(plist CFBundleVersion)
FEED_URL=$(plist SUFeedURL)
# The release goes wherever the app looks for updates.
[[ "$FEED_URL" =~ ^https://github\.com/([^/]+/[^/]+)/releases/latest/download/appcast\.xml$ ]] \
  || fail "SUFeedURL $FEED_URL is not a GitHub latest-release appcast URL."
REPO="${BASH_REMATCH[1]}"
TAG="v$VERSION"
ZIP="$BUILD_DIR/VoiceiQ-$VERSION.zip"
DMG="$BUILD_DIR/VoiceiQ-$VERSION.dmg"
NOTES="${RELEASE_NOTES:-release-notes/$VERSION.md}"
SPARKLE_NOTES="${SPARKLE_NOTES:-$NOTES}"
DOWNLOAD_PREFIX="https://github.com/$REPO/releases/download/$TAG/"

for file in "$ZIP" "$DMG" "$NOTES" "$SPARKLE_NOTES"; do
  [[ -f "$file" ]] || fail "$file is missing."
done
xcrun stapler validate "$APP_PATH" >/dev/null || fail "the app is not stapled; publish only what scripts/release.sh notarized."
published=""
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  [[ -n "${DRY_RUN:-}" ]] || fail "release $TAG already exists in $REPO. Bump MARKETING_VERSION and CURRENT_PROJECT_VERSION."
  published=1
fi

echo "▸ Fetching the current appcast"
rm -rf "$STAGE"
mkdir -p "$STAGE"
if [[ -n "$published" ]]; then
  # The live feed already lists this build, so a rehearsal checks a new feed.
  echo "  dry run of the published $TAG; starting a new feed"
else
  status=$(curl -sSL -o "$STAGE/appcast.xml" -w '%{http_code}' "$FEED_URL")
  case "$status" in
    200) ;;
    404) rm -f "$STAGE/appcast.xml"; echo "  none published yet; starting a new feed" ;;
    *) fail "fetching $FEED_URL returned HTTP $status." ;;
  esac
fi

if [[ -f "$STAGE/appcast.xml" ]]; then
  newest=$(grep -o '<sparkle:version>[0-9]*' "$STAGE/appcast.xml" | grep -o '[0-9]*$' | sort -n | tail -1)
  if [[ -n "$newest" ]] && (( BUILD <= newest )); then
    fail "build $BUILD is not newer than published build $newest; bump CURRENT_PROJECT_VERSION."
  fi
fi

echo "▸ Generating appcast for $VERSION ($BUILD)"
cp "$ZIP" "$STAGE/"
cp "$SPARKLE_NOTES" "$STAGE/VoiceiQ-$VERSION.md"
key_args=(--account voiceiq)
[[ -n "${SPARKLE_ED_KEY_FILE:-}" ]] && key_args=(--ed-key-file "$SPARKLE_ED_KEY_FILE")
"$SPARKLE_BIN/generate_appcast" "${key_args[@]}" \
  --download-url-prefix "$DOWNLOAD_PREFIX" \
  --embed-release-notes \
  --link "https://github.com/$REPO/releases" \
  "$STAGE"

swift scripts/verify-appcast.swift "$STAGE/appcast.xml" "$APP_PATH" "$ZIP" "${DOWNLOAD_PREFIX}VoiceiQ-$VERSION.zip"

if [[ -n "${DRY_RUN:-}" ]]; then
  echo "✓ Dry run: $STAGE/appcast.xml is ready; nothing was published."
  exit 0
fi

git diff --quiet HEAD || fail "the working tree has uncommitted changes; release from a commit."
git fetch --quiet origin
[[ -n "$(git branch -r --contains HEAD)" ]] || fail "HEAD is not pushed to origin; push it first."

echo "▸ Publishing $TAG to $REPO"
gh release create "$TAG" "$ZIP" "$DMG" "$STAGE/appcast.xml" \
  --repo "$REPO" \
  --target "$(git rev-parse HEAD)" \
  --title "VoiceiQ $VERSION" \
  --notes-file "$NOTES" \
  --latest

# GitHub's latest/download redirect can take several minutes to point at a
# new release (0.5.5 took over a minute), so wait up to 10 minutes.
FEED_WAIT_SECONDS=${FEED_WAIT_SECONDS:-600}
echo "▸ Checking the live feed (up to ${FEED_WAIT_SECONDS}s)"
started=$SECONDS
deadline=$((started + FEED_WAIT_SECONDS))
while :; do
  if [[ "$(curl -fsSL "$FEED_URL" || true)" == *"<sparkle:version>$BUILD<"* ]]; then
    echo "✓ $FEED_URL now offers $VERSION ($BUILD) after $((SECONDS - started))s"
    exit 0
  fi
  (( SECONDS >= deadline )) && break
  sleep 15
done
fail "$FEED_URL does not offer build $BUILD after ${FEED_WAIT_SECONDS}s; check the release's assets."
