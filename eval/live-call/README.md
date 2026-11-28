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
The owner's side is whatever the Mac's default input hears.

meet.jit.si opens a room only after a moderator signs in, so the throwaway
profiles wait in its lobby. `SITE=vdo` uses vdo.ninja instead: no sign-in,
each window's name shows on its tile, and it is in `CallApps.meetingPages`,
so VoiceiQ detects the call and reads names from the screen.

## What the probe needs

- A signed build of the commit under test, installed as `/Applications/VoiceiQ.app`.
  Do not test a Debug build (AGENTS.md).
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

The script:

1. Opens one Chrome window per guest WAV in the room, 3 s apart, named
   `Guest 1`, `Guest 2`, and so on. Each WAV is padded with silence so that
   every guest starts speaking with the owner, and plays once.
2. Opens the owner's window in the same room, using the real default
   microphone. VoiceiQ detects the call there. Accept the offer, or start
   recording with Option-M, within 30 s.
3. Checks that the owner hears every guest. Before anyone speaks, each
   guest beeps at its own pitch (500 Hz, 850 Hz, 1200 Hz…, 3 s apart), and
   `taprecord.swift` records the owner's Chrome through a Core Audio process
   tap. A guest whose pitch peaks below −45 dBFS there was not heard. The run
   stops, because a probe without the far side measures nothing; `CHECK=warn`
   goes on anyway. The recording and the levels are written to
   `$OUT/guest-check.wav` and `guest-check.txt`. The terminal or agent
   running the script needs System Audio Recording permission for the tap.
   Until 2026-11-28 no run checked this, and in every run so far the
   guests' audio never reached the owner
   (`activities/2026-11-28-silent-call-tap.md`).
4. Plays `owner.wav` into `OWNER_DEVICE`, or through `afplay` to the
   default output.
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
