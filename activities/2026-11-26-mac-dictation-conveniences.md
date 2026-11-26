# 2026-11-26: Mac dictation conveniences from Hex

## Why

Hex (anomalyco/hex, MIT) shipped several small Mac dictation fixes and
conveniences. These are the ones that fit VoiceiQ without changing its
defaults, screens or flows.

## What changed

- **Middle mouse button as the dictation key** (Hex `dc0e6e7c`). The dictation
  key recorder in Settings › Dictation also takes a middle click. With it
  chosen, holding the middle button still for half a second starts a
  hands-free dictation and the next hold stops it. Clicks, panning and
  autoscroll still reach the app, which gets every middle press either way.
  `DictationTrigger.middleMouse`, `MiddleMouseHold` (pure),
  `EventTapEngine`. The default stays fn.
- **A long dictation asks before ⌘Esc cancels it** (Hex `9d6e0990`). After 10
  seconds of recording, the first ⌘Esc keeps recording and the pill says
  "Press ⌘Esc again to cancel" for 3 seconds; a second ⌘Esc in that time
  cancels. Shorter dictations cancel at once, as before. A cancelled take of
  10 seconds or more was already kept in History with Retry, so this only
  saves the trip there; it is a pill notice, not a dialog. The pill's ×
  button cancels at once, since it is a deliberate click and the notice
  would cover it. `CancelConfirmation` (pure), wired in
  `DictationController`'s intent loop.
- **The pill comes back from a Space it was stranded on** (Hex `8c9489b6`).
  When the window server has tied the pill to another Space (another app's
  full-screen Space, a display change), the next reposition orders it in once
  with `.moveToActiveSpace`, then restores `.canJoinAllSpaces`. It does
  nothing while the pill is on the active Space. VoiceiQ is an accessory app,
  which Hex's report (a Dock app) was not, so this guards a rarer case.
- **Add to Dictionary… in the menu bar** (idea from Hex `9e9ce59f`). Opens the
  existing Dictionary pane with the cursor in the add row. No new window.
- **Clearer Dictionary fields** (Hex `dea95c0f`; FluidVoice `6e0c0b4e`
  studied for behaviour only). The add row's fields are labelled "Write it
  as" and "Heard as (optional)" above them on the Mac and beside them on the
  iPhone, with an example in each empty field, so the labels stay once the
  fields are filled and the two can't be swapped. Search over the list was
  already there on both.

## Not built

- **HUD on the mouse's screen** (Hex `59448fd4`): VoiceiQ already places the
  pill on the display under the pointer and follows the pointer while it is
  up (`PillHUDController.targetScreen`, `followMouse`).
- **Clipboard phrase** (Hex `be3ead04`): it could run as a deterministic step
  after the writing model, but on by default it would turn ordinary sentences
  ("I copied it to my clipboard") into pasted clipboard text. Hex ships it
  off, in Labs; VoiceiQ has no Labs area, so it would need a new opt-in
  setting for a niche gesture.
- **Shortcut to switch transcription source** (Hex `7a2c78ac`):
  `ShortcutStore` gives every action a default key combination and has no
  unassigned state, so one more optional shortcut means reworking the store,
  the recorder row and the conflict check.

## Verification

Pending Mac build. Written on Linux, so nothing was compiled. New tests:
`CancelConfirmationTests` and `MiddleMouseHoldTests` in
`VoiceIQCore/Tests/VoiceIQCoreTests`.
