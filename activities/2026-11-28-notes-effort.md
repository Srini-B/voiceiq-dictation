# 2026-11-28: Meeting notes at reasoning effort low

## Why

Release gate (a). With GPT-6 Luna at effort none, the notes model named
far-side voices in the echo meetings differently from run to run: on the
same transcripts, s3-four-people-echo was fully named in one run and missed
two names in the next, and s2-three-people-echo missed two in both. Those
names come from the notes (`notes.speakers`, then `byElimination`), so
naming in those meetings depends on the notes model. The Space decided on
effort low for notes only; dictation writing and meeting chat stay at none.

## What changed

`AssemblyAIClient.reasoningEffort(model:stage:)` returns `low` for GPT-6
models on the `meetingSummary` stage and `none` for every other stage.

## Variants measured

MeetingsEval, 9 meetings (AMI ES2004a and 8 synthetic), #129 b9b3a30 with
#127, transcripts reused from one STT-3.7 run, lobsters-mac-mini, LLM
Gateway. M1–M4 pooled from the meetings scorer; M5 judged by Fable (bar: AMI
90 or above, every synthetic 85 or above).

| Notes model | M1 / M2 / M3 / M4 | M5 mean (AMI, lowest synthetic) | Notes cost, 9 meetings | Notes time |
|---|---|---|---|---|
| luna, none (run 1) | 89.3 / 87.5 / 84.7 / 80.9 | 86.1 (92, 73) | $0.0084 | 67 s |
| luna, none (run 2) | 81.5 / 85.7 / 83.1 / 77.6 | not judged | $0.0083 | 68 s |
| luna, low | 98.9 / 90.5 / 87.2 / 86.4 | 85.3 (91, 60) | $0.0123 | 118 s |
| luna, medium | 98.9 / 90.5 / 87.2 / 86.4 | 91.9 (91, 85) | $0.0292 | 377 s |
| claude-haiku-5-5 | 98.9 / 90.5 / 87.2 / 86.4 | 87.8 (88, 60) | $0.0312 | 274 s |
| gemini-3.8-flash | failed: the gateway rejects the schema's `["string","null"]` type | | | |

Effort low fixes naming (M1–M4) but not notes content: its M5 misses are a
wrong s3 action list and an extra wrong item in s4-echo. Only medium passed
the M5 bar, once, with no margin on s3. A gemini-3.8-flash run with an
`anyOf` nullable schema and two more medium runs are pending.

Eval spend for these runs: about $0.10 in notes.
