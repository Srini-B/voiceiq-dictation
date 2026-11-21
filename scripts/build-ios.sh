#!/bin/bash
# Regenerates the Xcode project and builds the iOS app, keyboard and Live
# Activity for the Simulator (Debug, signed ad-hoc).
#
# A device build needs your team: build-ios.sh DEVICE=1 DEVELOPMENT_TEAM=XXXXXXXXXX

set -euo pipefail
cd "$(dirname "$0")/.."

# Hex's cleanup tagger model is a resource of the iPhone app (not in git).
scripts/fetch-hex-cleanup-model.sh
xcodegen generate

destination='generic/platform=iOS Simulator'
extra=()
for arg in "$@"; do
  case "$arg" in
    DEVICE=1) destination='generic/platform=iOS' ;;
    *) extra+=("$arg") ;;
  esac
done

exec env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all \
  xcodebuild build \
    -project VoiceIQ.xcodeproj \
    -scheme VoiceIQiOS \
    -configuration Debug \
    -destination "${destination}" \
    -quiet ${extra[@]+"${extra[@]}"}
