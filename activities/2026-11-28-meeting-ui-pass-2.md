# 2026-11-28 — Meeting UI pass 2 (M6)

Fable scored M6 at 90 for the Mac review screens, with no margin. This pass
takes the deductions that were left.

## Changes

- **Short replies stay inside a turn.** `MeetingSpeaker.turns(in:)` returns
  `TranscriptTurn`s. Another speaker's reply of one or two words ("Okay.",
  "Yes.") is an aside line in the current run: their name in their colour, the
  words in a secondary colour. It no longer starts a new heading. A lone
  letter ("a") is a transcription fragment and is left out. On AMI ES2004a,
  the first ten lines had seven headings before this change.
- **iPhone timestamp beside the name,** as on the Mac.
- **iPhone note header.** Folders, Redo and Export are now in one "More" (…)
  menu, so the title has the bar to itself. The bar is opaque, with a hard
  scroll edge on iOS 26 and later, so text no longer shows through under the
  clock. The "Ask about this note" placeholder uses the muted ink: 5:1, up
  from 1.7:1.
- **iPhone participants line.** It shows the coloured dots and names under
  the title, as on the Mac.
- **Dark sidebar selection.** It uses the system selection colour, as the
  Meetings list beside it does, instead of the pale `primary` #A8C7FA. Light
  mode keeps the brand blue (`VoiceIQUI.Colors.selection`).
- **Calendar match for overlapping events** (from the Hex watch, 566c99fc).
  The event whose call link names the detected call's service wins, then
  the only event under way, then the only one about to start. If nothing
  tells the events apart, no event is used. Before, the nearest start won,
  so a call that overlapped a later event took that event's title and
  invitees.

## Not done

- **Divider under the first day heading.** Neither `.listSectionSeparator(.hidden)`
  nor `scrollEdgeEffectHidden` removed it on macOS 27. It is the list's own
  header rule.
- **Recording pill and recording state.** These are not captured yet; they
  come next, before Fable scores M6 again.
- **Mac/iPhone wording.** "Meeting" on the Mac and "note" on the iPhone, and
  the rename chevron that only the iPhone has, are kept on purpose: a touch
  screen has no right-click.

## Backlog

- **Resume recording a finished meeting** (as Superwhisper 3.2.0 does). This
  helps when a call drops and reconnects. The new recording is added to the
  same meeting, and the notes and speakers are redone across both parts.
  Decided 2026-11-28 by the Space and the integrator: build it after this PR
  and the live-call probe, and only after the AssemblyAI meeting path has
  landed, so that it is built once, on the new transcriber. Revisit it once
  M6 is at target for the whole meetings UI.
