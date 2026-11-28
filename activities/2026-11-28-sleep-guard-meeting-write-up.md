# Sleep guard holds through a meeting's write-up

The request: while a dictation or a meeting is recording, and until its
transcript and notes are written, the Mac must not idle-sleep and its display
must not sleep or lock; the iPhone must not auto-lock while VoiceiQ is
dictating or recording notes, and recording must survive a manual lock or an
app switch.

Most of this already shipped in `SessionSleepGuard`
(activities/2026-10-10-session-sleep-guard.md): dictation held the lock
through insertion, and iOS already had the audio background mode, the
keep-alive audio session, and the Live Activity. The gap was meetings: the
guard let go at Stop, while AssemblyAI transcription and note writing went on
for minutes.

The guard now also holds while `MeetingEngine.processing` lists a meeting.
Every exit from the write-up (notes saved, transcript or notes failed, no
speech, waiting for AssemblyAI) clears that entry, and the AssemblyAI calls
carry deadlines; the guard also lets a write-up hold the lock for at most an
hour, so a step that never returns cannot keep the Mac awake. The display
stays on during the write-up as requested. The macOS activity
reason now reads "VoiceiQ is recording or transcribing a dictation or
meeting". The same rule applies on iOS, which keeps the screen on while notes
are written in the foreground.

## Verification

`SessionSleepGuardTests` read the process's power assertions from IOKit: a
meeting being written up holds PreventUserIdleSystemSleep and
PreventUserIdleDisplaySleep and lets go when the write-up fails; cancelling a
dictation and app shutdown let go. A third test drives the write-up hold with
a 1 s cap: on at once, off at the cap while a meeting stays stuck, off at
once when the write-up empties, and not extended by a meeting leaving.

Mac mini and iOS simulator runtime checks: pending.
