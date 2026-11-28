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
zmodload zsh/datetime  # EPOCHSECONDS

room=$1 seconds=$2 owner=${3:A}; shift 3
guests=(${@:A})
site=${SITE:-jitsi}
chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
# The run records with the installed app, so it holds the shared app lock
# (scripts/app-lock.sh); LOCK_OWNER names who holds it, such as a thread ID.
# A lock the caller already holds, for test-mode setup and teardown around
# the run, stays held when the run ends.
lockowner=${LOCK_OWNER:?set LOCK_OWNER to your thread ID}
applock=${0:A:h:h:h}/scripts/app-lock.sh
# Sparkle replaced the build under test mid-run on 2026-11-28 (0.7.17 to
# 0.7.18); a test Mac never updates the app on its own.
defaults write io.blue.voiceiq SUEnableAutomaticChecks -bool false
defaults write io.blue.voiceiq SUAutomaticallyUpdate -bool false
[[ -x $chrome ]] || { echo "Google Chrome is not installed" >&2; exit 1; }
command -v ffmpeg >/dev/null || { echo "ffmpeg is not installed" >&2; exit 1; }
scratch=$(mktemp -d /tmp/live-call.XXXXXX)
pids=()
here=${0:A:h}

cleanup() {
  for pid in $pids; do kill $pid 2>/dev/null || true; done
  sleep 2
  rm -rf $scratch
  (( callerlock )) || $applock release $lockowner
}
callerlock=0
$applock holds $lockowner && callerlock=1
trap cleanup EXIT
# Taken only once cleanup can release it.
$applock acquire $lockowner
# The lock goes stale 30 minutes after its last renewal; a run can be longer.
{ while sleep 600; do $applock holds $lockowner && $applock acquire $lockowner; done } &
pids+=$!
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
# guest i's beep 3i + 9 s after the owner joins, plus however long Chrome took
# to open the fake microphone.
# guestcheck.py hears a pitch only where it stands 15 dB above the others in
# the same 0.1 s frames, and no pitch's 2nd or 3rd harmonic lands on another:
# a whole-file peak per band passed a silent guest on speech, a clipped
# neighbour's harmonic or a chime (Neon on #142).
pitches=(500 700 1100 1300 1700 1900 2300 2900 3100)
(( ${#guests} <= ${#pitches} )) || { echo "at most ${#pitches} guests" >&2; exit 1; }
# Two words and no digits, as people are named in a call: ScreenSpeakerNames
# drops "Guest 1" as an interface label, so names could not be scored.
names=("Maya Patel" "Daniel Okafor" "Lena Fischer" "Ravi Shankar" "Sofia Moreno" "Tomas Novak" "Aiko Tanaka" "Omar Haddad" "Clara Jensen")
out=${OUT:-$PWD}
mkdir -p $out
: > $out/guest-check.txt
tone_at=$(( 3 * ${#guests} + 12 ))
# Seconds between the owner joining and everyone speaking: the last beep ends
# 3 × guests + 11 s in, the tap stops 6 s before the speech, and 6 s more
# allow for a slow microphone open.
lead=$(( 3 * ${#guests} + 23 > 30 ? 3 * ${#guests} + 23 : 30 ))
swiftc -O -suppress-warnings $here/taprecord.swift -o $scratch/taprecord
for index in {1..${#guests}}; do
  pad=$(( 3 * (${#guests} - index + 1) + lead ))
  ffmpeg -nostdin -loglevel error -i ${guests[index]} \
    -f lavfi -i "aevalsrc='0.4*sin(2*PI*${pitches[index]}*t)*pow(sin(PI*mod(t\,0.4)/0.25)\,2)*lt(mod(t\,0.4)\,0.25)':d=2:s=48000" \
    -filter_complex "[0]aresample=48000,adelay=${pad}000:all=1[g];[1]adelay=${tone_at}000:all=1[t];[g][t]amix=inputs=2:duration=longest:normalize=0" \
    -ar 48000 -ac 1 -c:a pcm_s16le $scratch/guest$index.wav
done
# Chrome's sandboxed audio service cannot read the file and sends silence
# instead, so the guests run it unsandboxed.
for index in {1..${#guests}}; do
  join $scratch/guest$index ${names[index]} webcam --mute-audio --use-fake-device-for-media-stream \
    --disable-features=AudioServiceSandbox \
    "--use-file-for-fake-audio-capture=$scratch/guest$index.wav%noloop"
  sleep 3
done

# A fresh profile has had no click, so Chrome would block the call's sound.
join $scratch/owner "Owner" "webcam&videodevice=0" --autoplay-policy=no-user-gesture-required
speech_at=$(( EPOCHSECONDS + lead ))
echo "$(date +%T) Owner joined. Accept VoiceiQ's offer or press Option-M within ${lead}s."
$scratch/taprecord $(( lead - 6 )) $out/guest-check.wav "--user-data-dir=$scratch/owner" &
tap=$!
pids+=$tap
tap_status=0; wait $tap || tap_status=$?
if (( tap_status == 3 )); then
  echo "the guest check recorded only zeros: this terminal lacks System Audio Recording permission, or the owner's Chrome played only silence" >&2; exit 1
elif (( tap_status != 0 )); then
  echo "the guest check could not tap the owner's Chrome" >&2; exit 1
fi
missing=0
python3 $here/guestcheck.py $out/guest-check.wav ${pitches[1,${#guests}]} > $scratch/check.txt || missing=$?
tee -a $out/guest-check.txt < $scratch/check.txt
if (( missing > 0 )); then
  echo "$(date +%T) $missing guest(s) not heard by the owner's Chrome: this run does not count." | tee -a $out/guest-check.txt
  [[ ${CHECK:-stop} == warn ]] || exit 1
fi
# The guests' files reach their speech at speech_at on their own; the owner
# starts on the same second, not whenever the check finished (Codex on #142).
(( EPOCHSECONDS < speech_at )) || echo "the guest check ran $(( EPOCHSECONDS - speech_at + 1 )) s past the speech start" >&2
echo "$(date -r $speech_at +%T) Speech starts."
if [[ -n ${OWNER_DEVICE:-} ]]; then
  $scratch/playto $OWNER_DEVICE $owner $speech_at &
else
  sleep $(( speech_at > EPOCHSECONDS ? speech_at - EPOCHSECONDS : 0 ))
  afplay $owner &
fi
player=$!
pids+=$player
# SECONDS of speech, counted from speech_at: playto may still be waiting for it.
sleep $(( speech_at + seconds > EPOCHSECONDS ? speech_at + seconds - EPOCHSECONDS : 0 ))
# Still playing is fine (cleanup stops it); one that ended must have ended
# well, or the owner's track was never played (Codex on #142).
if ! kill -0 $player 2>/dev/null; then
  wait $player || { echo "owner playback failed: this run does not count" >&2; exit 1; }
fi
echo "$(date +%T) Leaving the call; stop the recording if it is still running."
