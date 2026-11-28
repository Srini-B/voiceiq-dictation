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

CI on 5dab5c9 passed (352 core tests, Mac and iOS builds); the three
SessionSleepGuardTests passed on CI and on the Mac mini.

Mac mini, signed and notarized build of 72770a8 (nothing published; the
installed app was restored afterwards). `pmset -g assertions` showed both
assertions under the new reason during a dictation, none after Cancel, both
during a meeting recording, both still held after Stop while AssemblyAI
transcribed and wrote the notes (18:36:57 to 18:37:08), and none once the
meeting was saved. The failed write-up path was covered by the test only.

iOS Simulator (iPhone, iOS 27), Debug build of 50e8153: LLDB read
`isIdleTimerDisabled` NO before, YES while recording notes, NO after Stop.
With the app in the background and the simulator locked, mic.caf kept growing
(about 32 KB/s for over two minutes), the meeting came out 5:46 long, and the
lock screen showed the "Recording notes" Live Activity with Stop. The write-up
took 0.4 s (silent simulator mic), so YES during a write-up was not observed
on iOS. No physical iPhone was tested.

Seen in passing, not changed: the Live Activity's time read "8:--" about four
minutes in, and the Past notes row of a meeting in progress reads
"Recording · 0:00". A quit seen mid-dictation was first blamed on a
⌘Esc keystroke. It was another test thread's `osascript -e 'quit app id
"io.blue.voiceiq"'` (an ordinary quit Apple event, 13 s before the ⌘Esc), not
a VoiceiQ bug or crash; ⌘Esc cancels and the app stays up
(activities/2026-11-28-mac-app-lock.md).
