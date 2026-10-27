# iOS Control Center toggle stuck on after a keyboard cancel

2026-10-27.

## Why

The owner started a dictation from the VoiceiQ Dictate control and cancelled
it on the keyboard. The control stayed red. The next press only turned it
off, and a second press was needed to dictate. The same control on the Action
button did nothing when held.

## Cause

`SetDictationIntent` ran only when the value iOS passed differed from
`SharedStore.isDictating()`. A control left on passes `false` while nothing
records, so the press was dropped. The Action button runs the same intent with
the same stale value, so it did nothing too.

Why the control stays on is not verified. `VoiceSession.publish` does call
`ControlCenter.reloadControls(ofKind:)` when the phase leaves `recording`, but
the reload, made while the app is in the background, does not reach the
control. A stop or cancel pressed on the control itself is fine, because iOS
reloads the control after the intent returns.

## What changed

- `SetDictationIntent` ignores `value` and toggles the real state through
  `ActionButtonBridge.run`, like `ToggleDictationIntent`. A press on a control
  left on starts a dictation, and iOS reloads the control to on afterwards.

## Verification

- `scripts/build-ios.sh` (Simulator, Debug) succeeded.
- Not verified on a device: no iPhone was connected to the build Mac. Check
  on a TestFlight build: start from the control, cancel on the keyboard, then
  hold the Action button. It should start a new dictation on the first press.
