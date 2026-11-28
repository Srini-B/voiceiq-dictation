# iPhone keyboard: Adaptive touch switch (2026-11-28)

## Why

cyron asked whether the iPhone keyboard brings in all of Hex's typing work:
typing enhancements, swipe to type, the prediction bar and learning from how
you type. The keyboard is Hex's own code, synced from `f5819f4c`, and Hex
(`e8904f7d`, 2026-11-28) has no keyboard commits after it, so all four are in,
with two gaps:

- **Adaptive touch**, Hex's Labs option that moves each key's touch area toward
  where you tap it. The code was vendored, but VoiceiQ had no switch, so it was
  always off.
- **Learning from fixes to dictated text** (Hex's `DictationEditInference`):
  vendored, not wired. Handled separately.

## What changed

Settings › Keyboard & Permissions › Typing has an Adaptive touch switch, off
by default as in Hex, with Reset touch learning. Erase what it learned also
resets touch learning, as Hex's Delete what Hex learned does. The card writes
Hex's own App Group keys (`experiments.adaptiveTouch`, `adaptiveTouch.resetAt`);
no Hex file changed.

## Verification

See the PR: CI (App, iOS build, VoiceIQCore) and a Simulator capture of the
card from the Mac mini.
