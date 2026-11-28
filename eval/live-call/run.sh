#!/bin/zsh
# Live-call probe: guests with prepared WAVs join a meet.jit.si room in
# throwaway Chrome profiles; the owner joins with the default microphone.
# See README.md. Usage: run.sh ROOM SECONDS owner.wav guest1.wav [guest2.wav …]
set -euo pipefail

room=$1 seconds=$2 owner=$3; shift 3
chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[[ -x $chrome ]] || { echo "Google Chrome is not installed" >&2; exit 1; }
scratch=$(mktemp -d /tmp/live-call.XXXXXX)
pids=()

cleanup() {
  for pid in $pids; do kill $pid 2>/dev/null || true; done
  rm -rf $scratch
}
trap cleanup EXIT

join() { # profile-dir display-name [extra chrome flags…]
  local dir=$1 name=$2; shift 2
  "$chrome" --user-data-dir=$dir --no-first-run --no-default-browser-check \
    --use-fake-ui-for-media-stream "$@" \
    "https://meet.jit.si/$room#userInfo.displayName=%22$name%22&config.prejoinConfig.enabled=false" \
    >/dev/null 2>&1 &
  pids+=$!
}

index=1
for wav in "$@"; do
  join $scratch/guest$index "Guest $index" --use-fake-device-for-media-stream \
    --use-file-for-fake-audio-capture="$(cd "$(dirname $wav)" && pwd)/$(basename $wav)"
  index=$((index + 1))
  sleep 3
done

join $scratch/owner "Owner"
echo "Owner joined. Accept VoiceiQ's offer or press Option-M to record."
sleep 10
afplay "$owner" &
pids+=$!
sleep $seconds
echo "Leaving the call; stop the recording if it is still running."
