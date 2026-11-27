# 2026-11-26: Meeting decisions from runs already made

## Why

cyron stopped all Gemini use on 2026-11-26 at about 15:00 UTC, after the eval
key's prepaid credit ran out. He asked for the open meeting decisions to be
made from results already collected, with no new calls.

## Decisions

- **One notes call per meeting is measured, not estimated.** On AMI ES2004a
  (17.5 min), the notes call with the schema used 8,808 input and 480–753
  output tokens. That is $0.017–0.019 at January 2027 prices, about $0.06 per
  meeting hour (about ₹5.5 at ₹87/$). The cost study had assumed up to four
  notes calls, about ₹23 per hour. With PR #100's schema, 24 of 24 synthetic
  meetings made one call, except s4's planned rewrite after elimination.
- **Transcription cost per hour stays the cost study's estimate (about
  ₹31).** No transcription run was metered before the stop, and measuring it
  needs new calls. A meeting hour is therefore about ₹37: ₹31 estimated plus
  ₹5.5 measured.
- **The Flex tier is not used for notes.** 18 of 18 Flex requests returned 503
  (see 2026-11-26-meeting-cost-metering.md).
- **This branch (meeting-notes-stability) is parked, not opened as a PR.**
  - Its deadline rule ("tomorrow … in the evening" → "tomorrow evening") gave
    "tomorrow evening" in 4 of 4 s2 notes.
  - Its earlier one-task rule did not merge the split screenshot task.
  - Its section rule did not stop s3-echo's section names from varying.
  - The stronger one-task rule never ran.
  - M5 on main stays at 91.7 (PR #100), and an unscored prompt change could
    lower it.
- **Waiting on new calls:**
  - measured transcription cost per hour;
  - the held-out AMI IS1009a score;
  - the per-turn custom-vocabulary probe for AMI M3 and M4;
  - gemini-3.8-flash against 3.5-transcribe;
  - M5 for this branch.

## Hex's speaker naming from the call window: not ported now

Read anomalyco/hex `2609852c`, `0d4b2758` and `4ef808b7` (MIT).
- **What they do.** Every half second a reader records which tile the call
  app lights as speaking (the "floor"). Calibration checks that the user's
  own tile lights under the user's own microphone. A resolver then names each
  stretch of remote speech by who held the floor, and leaves words unnamed
  near a change of floor.
- **Hex's own state.** Hex has not wired them in. The probe in `4ef808b7` is
  a developer CLI with one Slack huddle fixture. Hex's numbers come from a
  simulation, not a call: 79.8% of words right and 11.9% wrong when each word
  takes whoever is lit at that moment. Its default rule gets 90.5% right where
  one person talks at a time, and 27.2% wrong on overlapped words.
- **Why not now.**
  - It cannot help the measured gap. M3 and M4 are under 90 only on AMI, an
    in-room meeting with no call window, and there the shortfall is Gemini's
    words (33% WER), not names. The synthetic calls already score 95 to 99 on
    M3.
  - It needs a live reader of the active-speaker highlight in Meet, Teams,
    Zoom and Slack. VoiceiQ has no such reader. `ScreenNameSampler` reads the
    names on screen, not which tile is lit.
  - Existing data holds no recorded floor evidence, so nothing can be tested
    without a live call.
  - On-device pyannote already splits the far side by voice. Hex measured a
    voice check of this kind at about the same accuracy as the floor rule.
- **Kept for when a live-call probe is possible.** Calibrating against the
  user's own tile and microphone, and treating a hidden window, two windows
  or a cut-short look as no look. Both would guard an active-speaker reader
  from naming people wrongly.
