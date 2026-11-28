# Silent call tap: diagnosis and quiet-track guard

**2026-11-28.** In the live-call probe on lobsters-mac-mini, meetings m2 and m3
wrote a `system.caf` that heard none of the call. The track wasn't zeros: it
was noise near −84 dBFS. The unified log showed "system tap started: 8 call
processes" and no rebuild, follow or error lines.

## What was ruled out

- **TCC.** The same app's tap of all audio recorded the call in m1.
- **Output routing.** With `tapprobe`, a standalone Core Audio tap CLI, on the
  Mac mini (thread T-01a22123), every Chrome process that played sound was
  heard at full level by its own tap and by a mixdown of call processes, in
  every routing tried:
  - to the default output;
  - to a non-default device through `setSinkId` (Jump Desktop Audio while
    the default was Speakers);
  - to both at once;
  - after the default output changed mid-play.
  A process tap is silent only for process objects that aren't playing
  (`isRunningOutput` false), which deliver no buffers at all. So
  `SystemAudioTap`'s premise, that a tap hears only the default output, doesn't
  hold on macOS 27.
- Side note: audio sent to Jump Desktop Audio reads 12 dB lower than on
  Speakers, so the device volume applies before the tap.

## Still open

The probe didn't reproduce m2/m3's other differences:
- the owner's Chrome audio service was in a duplex voice-processing call
  (input running);
- the tapped objects came from `CallDetector` at detection time;
- VoiceiQ's own mic engine was running on Jump Desktop Audio.

The next run uses a real call with the mic live, with and without a VoiceiQ
recording.

## Guard, shipped now

Whatever the cause, the app failed to notice:
- `SystemTapWatch.Silence` counted only exact zeros, and only after the track
  had carried sound, so a call that was never heard was never rebuilt.
- `SilentSystemAudio.check` flagged only all-zero tracks, so the "couldn't hear
  the other people" warning stayed hidden.

Both now treat a track as quiet when no sample is above −60 dBFS
(`SystemTapWatch.quietPeak`), and the watch counts from the start of the
recording. A rebuild still needs the tapped processes to be playing, and it
backs off 15, 60, then 240 s. So a call where nobody has spoken yet costs at
most a few seamless rebuilds.
