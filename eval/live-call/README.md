# Live-call probe

This probe runs a real call through the installed, signed VoiceiQ on a Mac and
checks what reaches the meeting folder. It measures:

- the capture itself: both tracks, their length against the call's, gaps and
  silence, and owner speech leaking into the far track;
- naming: the speaker names VoiceiQ finds on screen and through the calendar;
- the transcript, after AssemblyAI has processed the meeting.

The other participants are Chrome profiles in a meet.jit.si or vdo.ninja
room. Each one plays a prepared WAV as its microphone
(`--use-fake-device-for-media-stream --use-file-for-fake-audio-capture`) and
plays no sound itself (`--mute-audio`). VoiceiQ taps every Chrome process, so
a guest window that played the call would put the owner into `system.caf`.
Guests run Chrome's audio service unsandboxed
(`--disable-features=AudioServiceSandbox`): the sandboxed service cannot
read the WAV and sends digital silence without an error.
The owner's side is whatever the Mac's default input hears.

meet.jit.si opens a room only after a moderator signs in, so the throwaway
profiles wait in its lobby. `SITE=vdo` uses vdo.ninja instead: no sign-in,
each window's name shows on its tile, and it is in `CallApps.meetingPages`,
so VoiceiQ detects the call and reads names from the screen.

## What the probe needs

- The signed Release build of the commit under test, installed as
  `/Applications/VoiceiQ.app` and run in test mode (docs/DEBUG_LOG.md, Test
  mode), so the probe's meetings stay out of the owner's data and iCloud.
  Don't use a re-signed copy: granting it Screen Recording and Accessibility
  needs the admin password. With the app quit, save its settings
  (`defaults export io.blue.voiceiq <file>`), then set
  `defaults write io.blue.voiceiq DebugDisableCloudSync -bool true` and
  `defaults write io.blue.voiceiq DebugDataFolder /absolute/path`, launch it,
  and check its menu shows "Sync off (test)" and "Data in <path> (test)"
  before the call. Afterwards quit it, restore the settings exactly
  (`defaults delete io.blue.voiceiq`, then `defaults import io.blue.voiceiq
  <file>`; import alone merges), relaunch it and
  check neither "(test)" line is left (AGENTS.md). Do not test a Debug build.
- The shared app lock from test-mode setup to the end of teardown:
  `scripts/app-lock.sh acquire <thread ID>` before quitting the app, and
  `release` after the last menu check. `run.sh` takes the lock for the run
  (`LOCK_OWNER` set to your thread ID), renews it every 10 minutes so a long
  run doesn't outlast it, and leaves a lock you already hold in place, so
  nobody quits or reinstalls the real app under a probe. Setup and teardown
  outside the script must take under 30 minutes, the lock's stale age, or
  renew it with another `acquire`.
- `ASSEMBLYAI_API_KEY` set in the app, so the meeting is transcribed. Notes
  need an LLM Gateway balance. Without one they fail with `noBalance`, and
  the probe scores the transcript only.
- Google Chrome. The script creates throwaway profiles in a temporary
  directory, so it does not touch the user's own Chrome profile.
- An input device for the owner. A Mac mini has no built-in microphone. Use a
  USB microphone, or a loopback device, and play the owner's WAV into it
  with `OWNER_DEVICE` (below). Without one, the mic track is silent and only
  the far side is measured. Send the call's sound to an output the owner's
  input does not hear, such as the speakers; otherwise the guests reach the
  mic track too. Chrome can still play to the loopback: on the Mac mini with
  Jump Desktop Audio as both default input and loopback, the owner's Chrome
  played the call to the speakers and to Jump Desktop Audio, so the guests
  leaked into `mic.caf`.
- ffmpeg, which pads the guest WAVs and measures silence, and the Swift
  compiler from Xcode, which builds `playto.swift`.

## Run

```sh
SITE=vdo OWNER_DEVICE="Jump Desktop Audio" eval/live-call/run.sh ROOM SECONDS owner.wav guest1.wav [guest2.wav …]
```

`OWNER_DEVICE` names the loopback output (`system_profiler SPAudioDataType`
lists the devices). `playto.swift` plays the owner's WAV into it from memory.

The script turns off Sparkle's automatic checks and installs for VoiceiQ
(`SUEnableAutomaticChecks`, `SUAutomaticallyUpdate`), so an update cannot
replace the build under test mid-run. They stay off after the run; turn them
back on with `defaults delete io.blue.voiceiq SUEnableAutomaticChecks` and
`defaults delete io.blue.voiceiq SUAutomaticallyUpdate` on a Mac that is not
only for testing.

The script:

1. Opens one Chrome window per guest WAV in the room, 3 s apart, named
   with two-word names (Maya Patel, Daniel Okafor, Lena Fischer…; at most
   nine guests). ScreenSpeakerNames drops a name like "Guest 1" as an
   interface label. Each WAV is padded with silence so that every guest
   starts speaking with the owner, and plays once.
2. Opens the owner's window in the same room, using the real default
   microphone. VoiceiQ detects the call there. Accept the offer, or start
   recording with Option-M, within the lead the script prints (30 s, more
   with more than two guests).
3. Checks that the owner hears every guest. Before anyone speaks, each
   guest beeps at its own pitch (500, 700, 1100, 1300, 1700, 1900, 2300,
   2900, 3100 Hz, 3 s apart; no pitch's 2nd or 3rd harmonic is another's),
   and `taprecord.swift` records the owner's Chrome through a Core Audio
   process tap. It waits for an owner process that is playing sound and
   stops 6 s before the speech, whenever it started. `guestcheck.py` hears
   a guest only in 0.1 s frames where its pitch is above −50 dBFS and 15 dB
   above every other pitch, in at least four frames; speech, a clipped
   neighbour or a chime raises every pitch together and passes no one. The
   run stops if a guest was not heard, because a probe without the far side
   measures nothing; `CHECK=warn` goes on anyway. The recording and the
   results are written to `$OUT/guest-check.wav` and `guest-check.txt`.
   The terminal or agent running the script needs System Audio Recording
   permission for the tap; without it the tap records exact zeros, and the
   run says so instead of blaming the call.
   Until 2026-11-28 no run checked this, and in every run before then the
   guests' audio never reached the owner, because the sandboxed audio
   service sent silence (`activities/2026-11-28-silent-call-tap.md`).
4. Plays `owner.wav` into `OWNER_DEVICE`, or through `afplay` to the
   default output, at the second the guests' padding reaches their speech,
   however long the check took.
   Note that the beeps play while VoiceiQ already records, so they open
   `system.caf`.
5. Leaves the call after `SECONDS` and closes every window.

When the meeting has processed, run
`eval/live-call/collect.sh <meeting-folder> <out-dir>`. It copies `mic.caf`,
`mic-aec.caf`, `system.caf`, `meta.json`, `transcript.json`, `notes.json`
and the screen-name samples. It prints the recording's length, and for each
track its length, its share below −50 dBFS, and its runs of digital silence
(gaps).

Each guest WAV should carry one AMI speaker's close-talk channel. That way
the reference transcript and speaker turns come from the AMI annotations,
which `eval/meetings/prepare.py` already reads.
