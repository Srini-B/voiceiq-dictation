# 2026-11-12: Loud rooms on, resting indicator off by default

## Why

The owner's choice: "Better hearing in loud rooms" should be on by default,
and the resting pill at the bottom of the screen should be hidden by default.

## What changed

- `SettingsStore.experimentalNoiseHandling` now reads as on when the key was
  never written (Mac and iPhone; both apps use the same setting).
- `SettingsStore.showIdleIndicator` now reads as off when the key was never
  written (Mac only; the iPhone has no resting indicator).

## Existing installs

Both keys are written only when someone flips the toggle (or by the one-time
copy from the old bundle id's defaults, which copies only values a user had
set). So:

- A user who ever set either toggle keeps that value.
- A user who never touched a toggle gets the new default on the next launch:
  loud-room handling turns on, and the resting dot disappears, leaving the pill
  only while dictating. This matches how Real-time transcription was turned
  off on 2026-11-10.
