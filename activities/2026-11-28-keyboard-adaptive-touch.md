# iPhone keyboard: Adaptive touch always on (2026-11-28)

## Why

cyron asked whether the iPhone keyboard brings in all of Hex's typing work:
typing enhancements, swipe to type, the prediction bar and learning from how
you type. The keyboard is Hex's own code, synced from `f5819f4c`, and Hex
(`e8904f7d`, 2026-11-28) has no keyboard commits after it, so all four are in,
with two gaps:

- **Adaptive touch**, Hex's Labs option that moves each key's touch area toward
  where you tap it. The code was vendored, but it is off by default in Hex and
  VoiceiQ had no switch, so it never ran.
- **Learning from fixes to dictated text** (Hex's `DictationEditInference`):
  vendored, not wired. Handled separately.

cyron decided (2026-11-28): "Bring it but make it on and don't give option on
ui to turn off and keep improving it." A first draft of this PR added an
off-by-default switch; it was replaced before merge.

## What changed

- `0011-voiceiq-adaptive-touch-on.patch`: `AdaptiveTouchSettings.isEnabled`
  is always true, so the keyboard learns tap positions in every field Hex
  allows (never secure ones). No switch in Settings.
- Erase what it learned (Settings › Keyboard & Permissions › Typing) also
  resets touch learning, as Hex's Delete what Hex learned does: the recovery
  path if bad averages ever build up.
- The Learn how I type footnote says the keyboard always learns where you tap.

## Follow-up

The two-day upstream watch keeps checking Hex's Adaptive touch commits and
tunes it from there.

## Verification

See the PR: CI (App, iOS build, VoiceIQCore) and a Simulator capture of the
card from the Mac mini.
