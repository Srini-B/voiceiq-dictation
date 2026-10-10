# Session sleep guard and mobile bundle audit

The user requested sleep prevention during dictation and meeting recording,
and confirmation that local inference does not increase mobile downloads.

Added one SessionSleepGuard per app controller. It combines dictation state
with meeting phase rather than letting each independently reset the OS lock.
Dictation holds through insertion; meetings hold only while recording.
Completion, cancellation, failure, and app termination release protection.
The idle microphone warm window does not hold a lock.

macOS uses idle system/display sleep activities. iOS/iPadOS use the app's idle
timer and restore its prior value. This does not override another foreground
app's Auto-Lock, manual locking, Mac lid closure, or forced system sleep.
See docs/POWER_MANAGEMENT.md for the scope.

## Verification

- All 143 existing core tests passed.
- The Mac release flow produced a signed, notarized app and DMG. An installed
  verification copy acquired both PreventUserIdleSystemSleep and
  PreventUserIdleDisplaySleep during dictation, then released them after stop.
- A temporary command-line probe compiled the production guard with controlled
  state publishers. Seventeen checks read actual pmset assertions for active
  states, terminal states, overlapping sessions, meeting failure, and shutdown.
  These isolate the guard and do not simulate the audio engine.
- The Release iPhone simulator app's UIApplication idle timer read NO before
  a meeting, YES during recording, and NO after stopping, inspected with LLDB.
- The unsigned iOS device archive and Release simulator builds passed.
  Bundle audit and symbol inspection of app, keyboard, and Live Activity found
  no local inference runtime, normalizer, model management, or model weights.
  Uncompressed app files total 10,526,294 bytes. This is not an App Store
  compressed or device-thinned download measurement.
- Mac meeting runtime verification was blocked by a Core Audio startup stall.
  A process sample placed the main thread in SystemAudioTap.start(), waiting
  inside AudioDeviceStart, before MeetingEngine published recording. This
  separate audio-start issue was not changed. The temporary verification app
  was terminated, and the original installed app was restored.
- No physical iPhone/iPad idle-timeout test or forced sleep test was run.

## Delivery and rollback

Local changes only. No push, release publication, or installation on the user's
MacBook or mobile devices. Reverting the guard and its controller wiring removes
sleep prevention without changing stored preferences or downloaded models.
