# Silent call tap: diagnosis and quiet-track guard

**2026-11-28.** In the live-call probe on lobsters-mac-mini, meetings m2 and m3
wrote a `system.caf` that heard none of the call. The track wasn't zeros: it
was noise near −84 dBFS. The unified log showed "system tap started: 8 call
processes" and no rebuild, follow or error lines.

## Cause: the harness, not the tap

The guests' audio never reached the owner's Chrome. The evidence comes from
`tapprobe`, a standalone Core Audio tap CLI, run on the Mac mini in thread
T-01a22123:
- **A rerun with the guests unmuted.** Every Chrome process that played sound
  peaked at −80 to −89 dBFS through its own process tap, with and without a
  VoiceiQ recording running. That is WebRTC's near-silence, the same floor as
  m2 and m3.
- **Envelope correlation against the input WAVs.**
  - The owner's voice correlates 0.89–0.96 with `mic.caf`.
  - The three guests correlate at most 0.34 with any track, in m2, m3 and the
    rerun.
  - The "guest" voices in earlier transcripts are crosstalk in the owner's AMI
    headset channel.

The harness has to make guests audible (for example, a tone WAV as a guest's
fake mic) before it can test the call tap.

## Also learned

- **Output routing doesn't matter.** A process tap hears a process at full
  level whether it plays to the default output, to another device through
  `setSinkId`, to both, or across a change of default output. A tap is
  silent only for process objects that aren't playing, which deliver no
  buffers. `SystemAudioTap`'s premise, that a tap hears only the default
  output, doesn't hold on macOS 27; the output-move rebuild is harmless.
- **TCC wasn't involved:** the same app's tap of all audio recorded m1.
- **Device volume applies before the tap:** audio on Jump Desktop Audio read
  12 dB lower than on Speakers.
- **Call detection missed the rerun.** The owner's Chrome never had input
  running, so the app taped all audio instead of the call processes.

## Guard, shipped anyway (#137)

The app didn't notice an unheard call:
- `SystemTapWatch.Silence` counted only exact zeros, and only after the track
  had carried sound.
- `SilentSystemAudio.check` flagged only all-zero tracks.

Both now treat a track as quiet when no sample is above about −72 dBFS
(`SystemTapWatch.quietPeak` 8). That is 12 dB above the −84 dBFS floor and
12 dB below the −60 dBFS peak of quiet Meet speech that `TrackAudio.gain`
measured.

**Rebuild timing.** The watch waits 15 s from the start of the recording, and
60 s once the track has carried sound. That way the owner's long turn doesn't
rebuild the tap under the far side's reply. Neon (agy) flagged both the
−60 dBFS first draft and the 15 s wait after sound.

**Warning wording.** The Mac warning now depends on the cause:
- all zeros points to the System Audio Recording permission;
- noise says the others may have been muted the whole time or too quiet to
  record. That is what m2 and m3 were.
