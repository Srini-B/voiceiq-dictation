# Meeting waveforms: live split waveform and a playback bar

2026-11-28

## Why

The recording card showed two flat level bars ("You", "Call") and playback was a
Play icon in the header with no seek or speed. cyron asked for a live waveform
with you above the line and everyone else below it, and a playback bar with
controls built into the waveform, on Mac and iPhone.

## What

- A shared `MeetingWaveform.swift` in VoiceIQCore, styled per app, so the Mac and
  iPhone match.
- The live waveform replaces the level bars. iPhone's recorder card gains one
  (it had none) because its mic tap now feeds a `SoundClock`.
- `MeetingPlaybackBar` replaces the meeting's header Play on Mac and the Play
  button on iPhone. `RecordingPlayer` gained pause, seek and rate.

## Design references

Refero through Composio. Primary: Voicenotes (iPhone note detail mini-player:
pause, elapsed, track, total, back 15; web compact recording bar: red dot and
timer; monochrome, with red only for recording). Refero has no Voicenotes screen
with a live waveform, so the split waveform follows cyron's references, with
Moises and Memotron for the played/unplayed bars and playhead. We kept VoiceiQ's
own type and colours.

## Verification

See the PR for the build results and the Mac and iPhone recordings.
