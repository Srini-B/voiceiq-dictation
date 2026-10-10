# Sleep prevention during recording

`SessionSleepGuard` observes the dictation state and meeting phase together.
Each platform's app controller owns one guard.

- Dictation holds the lock from microphone startup through transcription and
  insertion. Completion, cancellation, or failure releases its claim.
- Meetings hold the lock while recording. Stopping or failing releases the
  claim; background transcription and note generation do not hold it.
- If both are active, finishing one leaves the other's lock intact.
- A detected call, an idle app, or an iOS microphone warm window does not
  prevent sleep. App termination explicitly releases the lock.

On macOS, `ProcessInfo.beginActivity` disables idle system sleep and idle
display sleep. Ending the activity restores the system's normal policy.
This does not override manual sleep, lid closure, or emergency power handling.

On iOS and iPadOS, `UIApplication.isIdleTimerDisabled` prevents Auto-Lock while
VoiceiQ is in the foreground. The guard restores the previous value when its
last claim ends. iOS does not let VoiceiQ prevent another foreground app from
auto-locking, or override the lock button. The existing background audio session
continues to govern recording while the keyboard's host app is in front.

This feature neither changes system sleep settings nor keeps local speech
models warm.
