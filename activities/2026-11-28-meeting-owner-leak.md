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

## Verification

See the PR: swift test and the meetings eval rerun on lobsters-mac-mini.
