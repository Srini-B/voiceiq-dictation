# Meetings M6 fixes (2026-11-28)

Fable scored the meetings experience M6 at 91 and listed what kept it from
higher. This change fixes those findings:

- The pill's Stop was blue while the window's Stop recording is red. Now it
  is red, and its level bars are one green, as the window meter's, instead
  of the brand colours, which read as a warning beside the record mark.
- The pill's × (Discard) read as closing the pill. It is a trash can now.
- In "Discard this recording?", Keep and Discard drew as identical grey
  chips. The pill's panel is never key, so macOS draws bordered system
  buttons inactive. The pill now draws its own capsules (`PillChip`). White
  text on `gRed` measured 3.9:1, so the red chips use `#B3261E` (6.5:1).
- "Unmute my mic" on its red tint measured 4.1:1. It is tinted with
  `Colors.error` now, about 8:1 in dark mode and 4.9:1 in light, calculated
  with the tint at the alpha that reproduces Fable's 4.1. The selected live
  row's time line uses the primary colour instead of secondary.
- Nothing showed between Stop and the notes' check while the Meetings window
  was closed. A "Making notes…" pill now shows until the check.
- Only "Today" drew a rule under its heading. Rows now name the call app.
  The empty pane explains itself and offers Record.
- Fable also flagged that the pill had no mute button. It has one now.
  AssignSpeakersView's shuffle button was unlabelled; it reads "Another
  line" now.

The pill was also centred in a 560 pt surface whatever its content. It now
fits its content (`fixedSize` after the max width).

Verification: Linux can't build this. The Mac mini builds it and runs the
package tests, and screenshots of a signed build follow in the PR.
