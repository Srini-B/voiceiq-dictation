# 2026-11-28: Meeting notes at reasoning effort medium

## Why

Release gate (a). With GPT-6 Luna at effort none, the notes model named
far-side voices in the echo meetings differently from run to run: on the
same transcripts, s3-four-people-echo was fully named in one run and missed
two names in the next, and s2-three-people-echo missed two in both. Those
names come from the notes (`notes.speakers`, then `byElimination`), so
naming in those meetings depends on the notes model. Notes content (M5)
must also clear the gate: AMI 90 or above and every synthetic meeting 85 or
above. The release thread's rule: gemini-3.8-flash if within 1 point of the
best passing variant, else the cheapest that passes. The Space first chose
low, then agreed to apply that rule once low's M5 came in under the bar.

## What changed

- `AssemblyAIClient.reasoningEffort(model:stage:)` returns `medium` for
  GPT-6 models on the `meetingSummary` stage and `none` for every other
  stage (dictation writing, meeting chat).
- Notes requests allow 32,000 output tokens (8,000 elsewhere), since
  reasoning counts against the limit, and a reply with
  `finish_reason: length` fails as `output_truncated` instead of failing to
  parse and being asked again into the same limit (review finding).
- The notes deadline is 15 minutes (was 5): AMI ES2004a (17 min) took
  33–59 s at medium, so a 2-hour call can need about 7 minutes (review
  finding). A cut-off reply shows its own message, without the Retry hint.

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
| luna, medium (run 2) | 98.9 / 90.5 / 87.2 / 86.4 | 92.8 (88, 85) | $0.0277 | 370 s |
| luna, medium (run 3) | 98.9 / 90.5 / 87.2 / 86.4 | 92.3 (91, 85) | $0.0250 | 326 s |
| gemini-3.8-flash, low, `anyOf` schema | 91.1 / 88.6 / 85.6 / 83.2 | 91.6 (92, 78) | $0.1420 | 76 s |

The first flash run failed every meeting: the gateway rejects the notes
schema's `["string","null"]` type for Gemini. `anyOf` with string and null
works for Gemini, Luna and Haiku (probe, 2026-11-28); the shipped schema is
unchanged since Luna is the pick.

## Pick

Luna at medium: M5 mean 92.3 over three runs (91.9–92.8), every synthetic
meeting 85 or above in all three, AMI 91 / 88 / 91 (the judge treats AMI as
sitting on the bar). Flash fails the bar on s3 (84) and s3-echo (78), so it
is not within reach of the rule's tie. Low trades content for naming (s3 62,
s4-echo 60). Notes at medium cost about $0.003 and 40 s a meeting, in the
background: cents a month at 4 meeting hours.

Known limit: s3-four-people is held at 85 by every model because its
transcript loses Rahul's "Spanish segment for one more week" line (missing
in 8 of 8 packets); the s3-echo write-up owner is weak in the transcript too.

Eval spend: about $0.36 in notes across all variant runs.
