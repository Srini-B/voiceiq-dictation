#!/bin/zsh
# Live-call probe: guests with prepared WAVs join a call room in throwaway
# Chrome profiles; the owner joins with the default microphone.
# See README.md. Usage: run.sh ROOM SECONDS owner.wav guest1.wav [guest2.wav …]
#   SITE=jitsi (default, meet.jit.si) or SITE=vdo (vdo.ninja, no sign-in).
#   OWNER_DEVICE="Device name" plays owner.wav into that output device, such as
#   a loopback the owner's default input hears. Without it, afplay plays it to
#   the default output.
#   OUT=dir keeps the guest check's recording and results (default: the
#   current directory). CHECK=warn goes on when a guest is not heard; by
#   default the run stops there, since a probe without the far side measures
#   nothing.
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
# Before anyone speaks, each guest beeps at its own pitch, 3 s after the one
# before, and a tap on the owner's Chrome must hear every pitch: in the first
# runs the guests' sound never reached the owner, and the probe could not
# tell. Every file opens 3 s after the previous one, so the same offset puts
# the beeps 3 s apart in the call.
out=${OUT:-$PWD}
mkdir -p $out
tone_at=$(( 3 * ${#guests} + 12 ))
pitch() { print $(( 500 + 350 * ($1 - 1) )) }
swiftc -O -suppress-warnings $here/taprecord.swift -o $scratch/taprecord
for index in {1..${#guests}}; do
  pad=$(( 3 * (${#guests} - index + 1) + lead ))
  ffmpeg -nostdin -loglevel error -i ${guests[index]} \
    -f lavfi -i "aevalsrc='0.4*sin(2*PI*$(pitch $index)*t)*lt(mod(t\,0.4)\,0.25)':d=2:s=48000" \
    -filter_complex "[0]aresample=48000,adelay=${pad}000:all=1[g];[1]adelay=${tone_at}000:all=1[t];[g][t]amix=inputs=2:duration=longest:normalize=0" \
    -ar 48000 -ac 1 -c:a pcm_s16le $scratch/guest$index.wav
done
# Chrome's sandboxed audio service cannot read the file and sends silence
# instead, so the guests run it unsandboxed.
for index in {1..${#guests}}; do
  join $scratch/guest$index "Guest $index" webcam --mute-audio --use-fake-device-for-media-stream \
    --disable-features=AudioServiceSandbox \
    "--use-file-for-fake-audio-capture=$scratch/guest$index.wav%noloop"
  sleep 3
done

# A fresh profile has had no click, so Chrome would block the call's sound.
join $scratch/owner "Owner" "webcam&videodevice=0" --autoplay-policy=no-user-gesture-required
echo "$(date +%T) Owner joined. Accept VoiceiQ's offer or press Option-M within ${lead}s."
sleep 8
owner_pids=($(pgrep -f -- "--user-data-dir=$scratch/owner"))
$scratch/taprecord $(( lead - 10 )) $out/guest-check.wav $owner_pids &
sleep $(( lead - 8 ))
wait $! || { echo "the guest check could not tap the owner's Chrome" >&2; exit 1; }
heard=0
for index in {1..${#guests}}; do
  level=$(ffmpeg -nostdin -hide_banner -i $out/guest-check.wav \
    -af "bandpass=f=$(pitch $index):width_type=h:w=60,volumedetect" -f null - 2>&1 | awk '/max_volume/ {print $5}')
  level=${level:--999}
  if (( level > -45 )); then result=heard; heard=$(( heard + 1 )); else result="NOT HEARD"; fi
  echo "Guest $index ($(pitch $index) Hz): peak ${level} dBFS at the owner, $result" | tee -a $out/guest-check.txt
done
if (( heard < ${#guests} )); then
  echo "$(date +%T) $(( ${#guests} - heard )) guest(s) not heard by the owner's Chrome: this run does not count." | tee -a $out/guest-check.txt
  [[ ${CHECK:-stop} == warn ]] || exit 1
fi
echo "$(date +%T) Speech starts."
if [[ -n ${OWNER_DEVICE:-} ]]; then
  $scratch/playto $OWNER_DEVICE $owner &
else
  afplay $owner &
fi
pids+=$!
sleep $seconds
echo "$(date +%T) Leaving the call; stop the recording if it is still running."
