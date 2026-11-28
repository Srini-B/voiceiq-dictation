# Sleep prevention during recording

`SessionSleepGuard` observes the dictation state and meeting phase together.
Each platform's app controller owns one guard.

- Dictation holds the lock from microphone startup through transcription and
  insertion. Completion, cancellation, or failure releases its claim.
- Meetings hold the lock while recording, then while their transcript and
  notes are written (`MeetingEngine.processing`). Saving the notes or failing
  releases the claim. A meeting waiting to retry AssemblyAI does not hold it.
- If both are active, finishing one leaves the other's lock intact.
- A detected call, an idle app, or an iOS microphone warm window does not
  prevent sleep. App termination explicitly releases the lock.

On macOS, `ProcessInfo.beginActivity` disables idle system sleep and idle
display sleep, so the display does not sleep and lock while it is held.
`pmset -g assertions` lists the activity under the reason "VoiceiQ is recording
or transcribing a dictation or meeting". Ending the activity restores the
system's normal policy. The AssemblyAI transcription deadline (15 minutes)
and the notes deadline bound how long a write-up can hold it.
This does not override manual sleep, lid closure, or emergency power handling.

On iOS and iPadOS, `UIApplication.isIdleTimerDisabled` prevents Auto-Lock while
VoiceiQ is in the foreground. The guard restores the previous value when its
last claim ends. iOS does not let VoiceiQ prevent another foreground app from
auto-locking, or override the lock button. The existing background audio session
continues to govern recording while the keyboard's host app is in front.

This feature does not change system sleep settings.
