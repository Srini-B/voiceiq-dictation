#!/bin/bash
# Archives the iOS app for the App Store and exports a signed IPA.
#
# Needs the "Apple Distribution" identity for team G8K3545FJ2 in a keychain
# and the three "VoiceiQ … App Store" provisioning profiles installed. See
# docs/IOS.md "TestFlight".
#
#   scripts/archive-ios.sh            # build number from project.yml
#   BUILD=13 scripts/archive-ios.sh   # override the build number
#
# Output: build/ios/VoiceiQ.xcarchive and build/ios/export/VoiceiQ.ipa

set -euo pipefail
cd "$(dirname "$0")/.."

out=build/ios
archive="$out/VoiceiQ.xcarchive"
rm -rf "$out"
mkdir -p "$out"

# Hex's cleanup tagger model is a resource of the iPhone app (not in git).
scripts/fetch-hex-cleanup-model.sh
xcodegen generate

build_args=()
if [ -n "${BUILD:-}" ]; then build_args+=("CURRENT_PROJECT_VERSION=$BUILD"); fi

env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all \
  xcodebuild archive \
    -project VoiceIQ.xcodeproj \
    -scheme VoiceIQiOS \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$archive" \
    -quiet ${build_args[@]+"${build_args[@]}"}

cat > "$out/ExportOptions.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>export</string>
  <key>teamID</key><string>G8K3545FJ2</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Apple Distribution</string>
  <key>provisioningProfiles</key>
  <dict>
    <key>io.blue.voiceiq.ios</key><string>VoiceiQ iOS App Store</string>
    <key>io.blue.voiceiq.ios.keyboard</key><string>VoiceiQ Keyboard App Store</string>
    <key>io.blue.voiceiq.ios.liveactivity</key><string>VoiceiQ Live Activity App Store</string>
  </dict>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath "$archive" \
  -exportOptionsPlist "$out/ExportOptions.plist" \
  -exportPath "$out/export"

ls -la "$out/export"
