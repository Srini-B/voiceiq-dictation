# Live-call probe

This probe runs a real call through the installed, signed VoiceiQ on a Mac and
checks what reaches the meeting folder. It measures:

- the capture itself: both tracks, their length against the call's, gaps and
  silence, and owner speech leaking into the far track;
- naming: the speaker names VoiceiQ finds on screen and through the calendar;
- the transcript, after AssemblyAI has processed the meeting.

The other participants are Chrome profiles in a meet.jit.si room. Each one
plays a prepared WAV as its microphone
(`--use-fake-device-for-media-stream --use-file-for-fake-audio-capture`). The
owner's side is whatever the Mac's default input hears.

## What the probe needs

- A signed build of the commit under test, installed as `/Applications/VoiceiQ.app`.
  Do not test a Debug build (AGENTS.md).
- `ASSEMBLYAI_API_KEY` set in the app, so the meeting is transcribed. Notes
  need an LLM Gateway balance. Without one they fail with `noBalance`, and
  the probe scores the transcript only.
- Google Chrome. The script creates throwaway profiles in a temporary
  directory, so it does not touch the user's own Chrome profile.
- An input device for the owner. A Mac mini has no built-in microphone. Use a
  USB microphone, or a loopback device, and play the owner's WAV into it.
  Without one, the mic track is silent and only the far side is measured.

## Run

```sh
eval/live-call/run.sh ROOM SECONDS owner.wav guest1.wav [guest2.wav …]
```

The script:

1. Opens one Chrome window per guest WAV in `https://meet.jit.si/ROOM`,
   named `Guest 1`, `Guest 2`, and so on.
2. Opens the owner's window in the same room, using the real default
   microphone. VoiceiQ detects the call there. Accept the offer, or start
   recording with Option-M.
3. Plays `owner.wav` through `afplay` when the owner has an input device
   that hears the speakers.
4. Leaves the call after `SECONDS` and closes every window.

When the meeting has processed, run
`eval/live-call/collect.sh <meeting-folder> <out-dir>`. It copies `mic.caf`,
`system.caf`, `meta.json`, `transcript.json` and the screen-name samples, and
prints each track's length and its share of silence.

Each guest WAV should carry one AMI speaker's close-talk channel. That way
the reference transcript and speaker turns come from the AMI annotations,
which `eval/meetings/prepare.py` already reads.
