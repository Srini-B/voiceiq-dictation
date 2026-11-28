# 2026-11-28: The owner's echo on the far side, and notes rate limits

## Why

Release gate (a), the meetings eval on AssemblyAI (main 671a680), failed on
AMI ES2004a: M1 90.0, M2 68.1, M3 77.5, M4 66.4 against Gemini's 100 / 84.7 /
81.9 / 79.2. The owner's voice leaked into the far track and came back as a
fifth speaker ("Sarah", from the owner's own introduction): 120 s and 362
words, 93% of its time inside the owner's turns. Scored with that speaker
dropped, the run read 100 / 82.8 / 81.5 / 80.2.

Two meetings also failed at the notes step on a gateway 429 (Retry-After
21–35 s). The app treated it as temporary, but retried only after 5 minutes.

## What changed

- `MeetingTranscriber.droppingOwnerEcho` removes far-side runs that repeat a
  simultaneous owner word (see docs/MEETINGS.md).
- `AssemblyAIClient.meetingNotesJSON` waits out a gateway 429 (at most 60 s,
  up to 4 asks) before the meeting falls back to its own waiting retry. The
  meetings eval calls the same function, so a 429 no longer scores as a
  failure.
- From Neon's review (agy, session e5a6275a): the echo drop removes only the
  matched stretch of a run, not the whole run, so a real reply under the
  leak's label less than a second later stays. `meetingNotes` gives all its
  asks one deadline and skips the missing-actions ask with under a minute
  left, so rate limits can't hold a meeting in "Making notes" for several
  deadlines; `meetingNotesJSON` stops once its deadline has passed (a wake
  from sleep during a wait).

## Verification

See the PR: swift test and the meetings eval rerun on lobsters-mac-mini.
