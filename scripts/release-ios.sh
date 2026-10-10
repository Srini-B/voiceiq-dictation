#!/bin/bash
# Test, archive, sign, upload, and distribute the iPhone app to TestFlight.
#
#   scripts/release-ios.sh                 # upload with asc (scripts/setup-asc.sh once)
#   UPLOAD=xcode scripts/release-ios.sh    # upload with the Xcode account instead
#   UPLOAD=none scripts/release-ios.sh     # everything except the upload
#   TEST_NOTES_FILE=notes.txt scripts/release-ios.sh   # TestFlight "What to Test"
#   SKIP_TESTS=1 scripts/release-ios.sh
#
# The build number is CURRENT_PROJECT_VERSION, shared with the Mac app; the
# script stops if TestFlight already has it. asc signs in with the ASC_KEY_ID,
# ASC_ISSUER_ID and ASC_PRIVATE_KEY_* variables when set (CI), otherwise with
# the stored profile "voiceiq".
#
# Steps: preflight → scripts/test.sh → build number → scripts/archive-ios.sh →
# verify signatures → upload → wait for processing → What to Test. The
# "VoiceiQ Internal" TestFlight group has automatic distribution and picks the
# build up. See docs/RELEASING.md "iPhone (TestFlight)".

set -euo pipefail
cd "$(dirname "$0")/.."

APP_ID=6816685189
TEAM_ID=G8K3545FJ2
GROUP="VoiceiQ Internal"
if [[ -n "${ASC_KEY_ID:-}" ]]; then
  asc_auth=()
else
  asc_auth=(--profile "${ASC_PROFILE:-voiceiq}")
fi
UPLOAD="${UPLOAD:-asc}"
ARCHIVE=build/ios/VoiceiQ.xcarchive
IPA=build/ios/export/VoiceiQ.ipa

fail() { echo "error: $*" >&2; exit 1; }

echo "▸ Preflight"
# The release Mac keeps the distribution key in its own keychain, unlocked with
# a password file only the release user can read (docs/RELEASING.md).
signing_keychain="$HOME/Library/Keychains/voiceiq-signing.keychain-db"
if [[ -f "$signing_keychain" && -f "$HOME/.voiceiq-signing/keychain.pass" ]]; then
  security unlock-keychain -p "$(cat "$HOME/.voiceiq-signing/keychain.pass")" "$signing_keychain"
fi
command -v xcodegen >/dev/null || fail "xcodegen is missing: brew install xcodegen"
# Captured before matching: with pipefail, `grep -q` exiting early can fail the
# pipeline even when it matched.
[[ "$(security find-identity -v -p codesigning)" == *"Apple Distribution: "*"($TEAM_ID)"* ]] \
  || fail "no 'Apple Distribution' identity for $TEAM_ID in the keychain (docs/RELEASING.md)"
profiles_dir="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
for name in "VoiceiQ iOS App Store" "VoiceiQ Keyboard App Store" "VoiceiQ Live Activity App Store"; do
  found=0
  for file in "$profiles_dir"/*.mobileprovision; do
    [[ -e "$file" ]] || continue
    if [[ "$(security cms -D -i "$file" 2>/dev/null | plutil -extract Name raw -o - - 2>/dev/null)" == "$name" ]]; then
      found=1; break
    fi
  done
  [[ $found == 1 ]] || fail "provisioning profile '$name' is not installed (docs/RELEASING.md)"
done
case "$UPLOAD" in
  asc)
    command -v asc >/dev/null || fail "asc is missing: brew install asc, then scripts/setup-asc.sh"
    asc ${asc_auth[@]+"${asc_auth[@]}"} apps view --id "$APP_ID" --output json >/dev/null 2>&1 \
      || fail "asc cannot reach app $APP_ID; run scripts/setup-asc.sh or use UPLOAD=xcode"
    ;;
  xcode|none) ;;
  *) fail "UPLOAD must be asc, xcode or none" ;;
esac

if [[ -z "${SKIP_TESTS:-}" ]]; then
  echo "▸ Testing VoiceIQCore"
  scripts/test.sh
fi

VERSION=$(awk '/MARKETING_VERSION:/ {gsub(/"/, "", $2); print $2; exit}' project.yml)
BUILD=$(awk '/CURRENT_PROJECT_VERSION:/ {gsub(/"/, "", $2); print $2; exit}' project.yml)
if [[ "$UPLOAD" == asc ]]; then
  next=$(asc ${asc_auth[@]+"${asc_auth[@]}"} builds next-build-number --app "$APP_ID" --platform IOS --output json \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["nextBuildNumber"])')
  (( BUILD >= next )) || fail "TestFlight already has build $((next - 1)); raise CURRENT_PROJECT_VERSION in project.yml above it"
fi
echo "▸ Version $VERSION ($BUILD)"

echo "▸ Archiving"
BUILD="$BUILD" scripts/archive-ios.sh
python3 scripts/check-app-bundle.py "$ARCHIVE/Products/Applications/VoiceiQ.app"

echo "▸ Verifying signatures"
payload=$(mktemp -d)
trap 'rm -rf "$payload"' EXIT
ditto -x -k "$IPA" "$payload"
app="$payload/Payload/VoiceiQ.app"
codesign --verify --deep --strict "$app"
for bundle in "$app" "$app"/PlugIns/*.appex; do
  entitlements="$payload/entitlements.plist"
  codesign -d --entitlements - --xml "$bundle" > "$entitlements" 2>/dev/null
  entitlement() { /usr/libexec/PlistBuddy -c "Print :$1" "$entitlements" 2>/dev/null || true; }
  [[ "$(entitlement com.apple.security.application-groups:0)" == group.io.blue.voiceiq ]] \
    || fail "$(basename "$bundle") lacks the App Group"
  [[ "$(entitlement get-task-allow)" != true ]] || fail "$(basename "$bundle") has get-task-allow"
done

# Exporting an App Store IPA registers a build upload for this number that
# stays "awaiting upload". Clear it so asc can upload the same number, and so
# a dry run leaves nothing behind.
clear_reservations() {
  command -v asc >/dev/null || return 0
  asc ${asc_auth[@]+"${asc_auth[@]}"} builds uploads list --app "$APP_ID" --output json 2>/dev/null \
    | python3 -c 'import json,sys
for u in json.load(sys.stdin).get("data", []):
    a = u["attributes"]
    if a.get("cfBundleVersion") == sys.argv[1] and a.get("state", {}).get("state") == "AWAITING_UPLOAD":
        print(u["id"])' "$BUILD" \
    | while read -r id; do asc ${asc_auth[@]+"${asc_auth[@]}"} builds uploads delete --id "$id" --confirm >/dev/null; done
}

if [[ "$UPLOAD" == none ]]; then
  clear_reservations
  echo "✓ $IPA is signed and ready; not uploaded (UPLOAD=none)"
  exit 0
fi

echo "▸ Uploading ($UPLOAD)"
if [[ "$UPLOAD" == asc ]]; then
  clear_reservations
  # "VoiceiQ Internal" has automatic distribution, so a processed build joins
  # it without an explicit add.
  asc ${asc_auth[@]+"${asc_auth[@]}"} publish testflight --app "$APP_ID" --ipa "$IPA" \
    --upload-only --wait --timeout 60m --output table
  if [[ -n "${TEST_NOTES_FILE:-}" ]]; then
    asc ${asc_auth[@]+"${asc_auth[@]}"} builds test-notes create --app "$APP_ID" --build-number "$BUILD" \
      --platform IOS --version "$VERSION" --locale en-US --whats-new "$(cat "$TEST_NOTES_FILE")" --output table
  fi
  asc ${asc_auth[@]+"${asc_auth[@]}"} testflight groups list --app "$APP_ID" --output table
else
  # Xcode's signed-in account uploads the archive. Run this from the logged-in
  # desktop session: signing needs the unlocked login keychain.
  options=$(mktemp)
  cat > "$options" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PLIST
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$options" \
    -exportPath build/ios/upload -allowProvisioningUpdates
  echo "Uploaded. \"$GROUP\" has automatic distribution, so the build reaches it after processing."
fi

echo "✓ VoiceiQ iOS $VERSION ($BUILD) is on TestFlight"
