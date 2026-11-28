# iPhone keyboard: Adaptive touch always on (2026-11-28)

## Why

cyron asked whether the iPhone keyboard brings in all of Hex's typing work:
typing enhancements, swipe to type, the prediction bar and learning from how
you type. The keyboard is Hex's own code, synced from `f5819f4c`, and Hex
(`e8904f7d`, 2026-11-28) has no keyboard commits after it, so all four are in,
with two gaps:

- **Adaptive touch**, Hex's Labs option that learns where you actually tap
  each letter key and scores auto-correction and suggestions against that. The code was vendored, but it is off by default in Hex and
  VoiceiQ had no switch, so it never ran.
- **Learning from fixes to dictated text** (Hex's `DictationEditInference`):
  vendored, not wired. Handled separately.

cyron decided (2026-11-28): "Bring it but make it on and don't give option on
ui to turn off and keep improving it." A first draft of this PR added an
off-by-default switch; it was replaced before merge.

## What changed

- `0011-voiceiq-adaptive-touch-on.patch`: `AdaptiveTouchSettings.isEnabled`
  is always true, so the keyboard learns tap positions in every field Hex
  allows (never secure ones). No switch in Settings. In Hex, turning it on
  takes Learn how I type's per-key offsets out of the decoder; on for everyone
  that would drop them for every user until Adaptive touch has a profile
  (400 taps over 3 sessions), so the patch keeps them in use while Adaptive
  touch has no offsets for the layout.
- The keyboard saves Adaptive touch's averages when it goes off screen
  (`TypingBridge.disappeared`); VoiceiQ doesn't vendor Hex's controller, which
  does this, so without it they were written only every 400 taps.
- Erase what it learned (Settings › Keyboard & Permissions › Typing) also
  resets touch learning, as Hex's Delete what Hex learned does: the recovery
  path if bad averages ever build up.
- The Learn how I type footnote says the keyboard also learns where you tap
  each key, even with that switch off.

## Follow-up

The two-day upstream watch keeps checking Hex's Adaptive touch commits and
tunes it from there.

## Verification

Fable 5.2 review of `c27b593`: 78, findings fixed in the next commit (save
on hide, journal offsets during warm-up, wording). `scripts/sync-hex-keyboard.sh`
against `f5819f4c` applies patches 0001-0011 cleanly and reproduces the tree.
CI and the Simulator capture are on the PR.
