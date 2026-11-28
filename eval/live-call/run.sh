#!/bin/zsh
# Live-call probe: guests with prepared WAVs join a call room in throwaway
# Chrome profiles; the owner joins with the default microphone.
# See README.md. Usage: run.sh ROOM SECONDS owner.wav guest1.wav [guest2.wav …]
#   SITE=jitsi (default, meet.jit.si) or SITE=vdo (vdo.ninja, no sign-in).
#   OWNER_DEVICE="Device name" plays owner.wav into that output device, such as
#   a loopback the owner's default input hears. Without it, afplay plays it to
#   the default output.
set -euo pipefail

room=$1 seconds=$2 owner=${3:A}; shift 3
guests=(${@:A})
site=${SITE:-jitsi}
lead=30 # seconds between the owner joining and everyone starting to speak
chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[[ -x $chrome ]] || { echo "Google Chrome is not installed" >&2; exit 1; }
command -v ffmpeg >/dev/null || { echo "ffmpeg is not installed" >&2; exit 1; }
scratch=$(mktemp -d /tmp/live-call.XXXXXX)
pids=()
here=${0:A:h}

cleanup() {
  for pid in $pids; do kill $pid 2>/dev/null || true; done
  sleep 2
  rm -rf $scratch
}
trap cleanup EXIT
trap "exit 1" INT TERM

url() { # display-name video-parameter
  local name=${1// /%20}
  case $site in
    jitsi) print "https://meet.jit.si/$room#userInfo.displayName=%22$name%22&config.prejoinConfig.enabled=false" ;;
    # Guests send the fake camera; the owner, on a Mac without one, sends none.
    vdo) print "https://vdo.ninja/?room=$room&label=$name&autostart&showlabels&$2" ;;
    *) echo "unknown SITE $site" >&2; exit 1 ;;
  esac
}

join() { # profile-dir display-name video-parameter [extra chrome flags…]
  local dir=$1 name=$2 video=$3; shift 3
  "$chrome" --user-data-dir=$dir --no-first-run --no-default-browser-check \
    --use-fake-ui-for-media-stream "$@" "$(url $name $video)" >/dev/null 2>&1 &
  pids+=$!
}

# Guests are muted: VoiceiQ taps every Chrome process, so a guest window that
# played the call would put the owner and the other guests into system.caf.
# Each guest's file starts when its window opens the fake microphone, so it is
# padded to start speaking when the owner does.
if [[ -n ${OWNER_DEVICE:-} ]]; then
  swiftc -O -suppress-warnings $here/playto.swift -o $scratch/playto
fi
for index in {1..${#guests}}; do
  pad=$(( 3 * (${#guests} - index + 1) + lead ))
  ffmpeg -nostdin -loglevel error -i ${guests[index]} -af "adelay=${pad}000:all=1" -ar 48000 -ac 1 -c:a pcm_s16le $scratch/guest$index.wav
done
for index in {1..${#guests}}; do
  join $scratch/guest$index "Guest $index" webcam --mute-audio --use-fake-device-for-media-stream \
    "--use-file-for-fake-audio-capture=$scratch/guest$index.wav%noloop"
  sleep 3
done

# A fresh profile has had no click, so Chrome would block the call's sound.
join $scratch/owner "Owner" "webcam&videodevice=0" --autoplay-policy=no-user-gesture-required
echo "$(date +%T) Owner joined. Accept VoiceiQ's offer or press Option-M within ${lead}s."
sleep $lead
echo "$(date +%T) Speech starts."
if [[ -n ${OWNER_DEVICE:-} ]]; then
  $scratch/playto $OWNER_DEVICE $owner &
else
  afplay $owner &
fi
pids+=$!
sleep $seconds
echo "$(date +%T) Leaving the call; stop the recording if it is still running."
