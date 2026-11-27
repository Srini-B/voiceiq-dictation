# 2026-11-27: Meetings UI pass (M6)

## Why

M6 scores the meetings UI against Granola. Rendered on an Amp Mac satellite
with four saved eval meetings, the Mac window had four problems:

- The transcript repeated the speaker heading on every line. In AMI
  ES2004a the note owner had four headings in ten seconds.
- The time under each name was meant to sit on a right tab stop, but it
  wrapped onto its own line, so every turn took three lines.
- The title was shown twice, in the header and at the top of the notes, and
  the notes did not say when the meeting was or who was in it.
- Each list row took three lines: the title, a full date range, and the
  length.

## What changed

- **Turns.** `MeetingSpeaker.turns(in:)` (VoiceIQCore) groups lines in a row
  by the same speaker. The Mac transcript column and the iPhone Transcript
  card show one heading per turn: the name in its colour, with the turn's
  start time beside it. Every line keeps its own `TranscriptSegment.id`, so
  Edit and Delete still work on one line (right-click on the Mac, touch and
  hold on iPhone).
- **Notes header (Mac).** Under the title: the day, start time and length,
  then everyone heard, with the owner first and each person marked by a dot
  in their transcript colour.
- **Header (Mac).** The title shows in the header only when the transcript
  fills the pane (narrow window). Otherwise the notes start with the title.
- **List (Mac).** One section per day (Today, Yesterday, then the date). Each
  row shows the title, then "11:50 PM · 17m", with the status after the
  length while the meeting is in flight or has failed.

## Decisions

- The live recording pill is unchanged. It needs a live recording to judge,
  and that comes with the live-call probe.
- The iPhone list already shows the date and length on one line, so only
  its transcript changed.

## Verification

- `swift test --package-path VoiceIQCore`: 331 tests, 0 failures, including
  the new `testTurnsGroupOnlyAdjacentLinesOfOneSpeaker`.
- The VoiceIQ (macOS) and VoiceIQiOS (simulator, arm64) schemes build
  unsigned on the satellite (macos-27). The lobsters-mac-mini runner was
  not listed.
- Before and after screenshots were taken of the Mac window in its wide
  layout and with the transcript alone, and of the iPhone 17 Pro simulator's
  transcript. The fixtures are saved eval outputs for s3 and AMI ES2004a.
- The right-click menu was not exercised: the satellite does not let
  synthetic clicks through. The menu still reads the segment id under the
  pointer, and every line keeps its id.

## Rollback

Revert the merge commit. Nothing is stored differently.
