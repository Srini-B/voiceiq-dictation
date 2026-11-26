# 2026-11-26: backup request delay back to a 20 s ceiling

## Decision

The dictation backup request's delay goes back to 0.7.16's settings: the 90th percentile of recent answer times, between 4 s and 20 s, starting at 8 s. PR #95 had capped it at 6 s.

## Why

The decision rests on runs collected earlier today. The Gemini eval key has no credit left, so no new calls were made.

Pooled D5 runs (three paired slots, every option on, screen context included, 198 calls per build):

| Build | p50 | p90 | D5 | Calls with a backup |
| --- | --- | --- | --- | --- |
| 0.7.16 (20 s ceiling) | 3.19 s | 6.99 s | 62.2 | 29 of 198 (15%) |
| #95 (6 s ceiling) | 3.29 s | 9.20 s | 38.6 | 44 of 198 (22%) |

- Every call that took longer than 6 s under #95 had its backup sent. Even so, single calls took 46.6 s, 25.8 s and 19.3 s. When the API is slow, both requests are slow, so a backup at 6 s cannot bring an answer much before 9 s.
- For D5 to reach 90 at a 3 s median, p90 has to be 4.5 s or less. No backup that waits 6 s can deliver that. Latency work has to shorten the request itself, not add calls.
- Fable 5.2 agreed that the data supports going back to the 20 s ceiling. It noted that turning the backup fully off has never been measured, and that the backup is the only rescue for a hung call, so it stays.
- Fable asked whether some slow calls missed their backup. The per-call records show they did not: every call over 6 s has `secondRequests = 1`.

The differences between the slots are uneven (−47.0, −12.6, +0.2), and #95 also changed the prompt. Both D5 scores are provisional until a pooled run can be made with credit.

## Verification

`swift test --package-path VoiceIQCore` runs in CI. The change touches two constants only.
