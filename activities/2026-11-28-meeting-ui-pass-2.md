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

- **Review fixes** (Codex and Fable at da97b09, scored 94):
  - Search keeps the run's speaker as the heading. Before, hiding a turn's first line put an aside speaker's name over the owner's words.
  - A reply is an aside only if it is at most 20 characters, so a Chinese or Japanese turn without spaces keeps its own heading.
  - The Teams app matches both teams.microsoft.com and teams.live.com links.
  - On the iPhone the note title shows once. The bar takes the title only after the page's large title has scrolled away. The kind badge sits on the date line, and the ask field says "meeting" when the badge does.
- **Neon review of da97b09:**
  - A short line becomes an aside only when the run's speaker goes on after it, or when it is the transcript's last line. "Good point." before the same speaker's longer line keeps its heading.
  - Only a lone Latin letter is a fragment: "B.", "I.", digits and one-character words in other scripts stay, and Mac search stops matching what the turns hide.
  - The calendar no longer falls back to an upcoming event while two are under way. Service links are matched by host, so notzoom.us does not count as zoom.us. Slack is never the matched service, as in `joinApps`.
  - On iPhone, an aside's context menu can name its speaker.
  - In dark mode the selected text colour follows the system.
- **Focus ring on "History":** the satellite has full keyboard navigation on (`AppleKeyboardUIMode` = 2), so the first sidebar button takes focus. With the default setting it does not show.
- **Play and Download stay visible but disabled** when a meeting has no audio, as decided on 2026-11-12 (9d7dd3e). The UI fixtures have no audio, so those buttons show disabled in the captures.

- **Recording state** (Fable, M6 92 at 6d0e946, and the integrator's order before merge):
  - While a meeting records, the notes pane shows a red mark, a running time and a live level for "You" and "Call". `SoundClock.level` is the last buffer's RMS, and `MeetingEngine.liveLevels` exposes it. "Discard…" moved there from beside Mute.
  - The row shows a red dot with the ticking length and "Recording".
  - An untitled meeting is called "Meeting" in both the row and the pane; the time is only on the row's second line.
  - Stop recording was already a red prominent button. Fable's capture showed it grey because Finder was the active app.
- **Short replies, further:** two short replies in a row from different people stay asides. Text without spaces counts as short only up to 6 characters.
- **iPhone title,** further: the bar takes the title once the page title passes the bar's measured bottom, not a fixed 100 pt (Neon). The ask field's noun uses the same test as the badge.

- **Neon review of d9833ed (agy):**
  - The look-ahead stops at the replying speaker's own next line, so someone who goes on in short lines keeps the floor.
  - Short text counts as unspaced (6-character cap) by script: Han, kana, Hangul or Thai. A short Russian reply stays an aside.
  - A recording that starts is selected, and stays listed under a folder filter.
  - The Discard dialog lives on the pane and closes when recording stops.
  - The live card is passed as a view, no longer found by matching the text "Recording".
  - A level expires after 0.5 s without buffers, so a detached tap reads as quiet.
  - The recording row's text is in the secondary colour; only its dot is red.
  - The iPhone title test runs only when the threshold is crossed.
- **Neon review of 05b6c00 (agy session 2a22ab10):**
  - Selecting another meeting, including a recording that starts and selects itself, closes an open Delete or Rename dialog, and Delete refuses a meeting that is busy.
  - Korean is no longer treated as unspaced, because it spaces its words.
  - Two Han, kana, Thai, Lao, Myanmar or Khmer letters are enough to count text as unspaced.
  - The list keeps a meeting that is being processed, and keeps the order.
  - The level clock uses system uptime.

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
