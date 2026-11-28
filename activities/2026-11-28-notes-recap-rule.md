# 2026-11-28: Meeting notes: a closing recap creates no new action

## Why

s4-names-unsaid-echo was the one meeting still under the M5 bar of 85
after the s3 audio was rebuilt. It ends with Jordan's recap, "Usage
numbers by Friday then, and Dana calls them Monday", which STT-3.7 hears
as "You'll set numbers by Friday then" in every run. On the old prompt, the
notes added a Friday "Set the numbers" item, given to Dana or to no one, in
5 of 6 runs on identical transcripts, and dropped the Friday date from
Kenji's real item. The release thread asked for a general rule, measured on
all 9 meetings × 3 runs, and accepted only if s4-echo improves and no other
meeting's 3-run mean drops by more than 1 point.

## What changed

`MeetingNotesPrompt.rules` has a `recaps` rule under actions. A closing
recap restates tasks and creates no new action. Each recapped task matches
its earlier commitment and takes the deadline the recap states. A task the
recap gives a named person for the first time is a new action. A recapped
phrase that names no one and matches nothing earlier is not an action.
`docs/design/meeting-prompt-rulebook.md` has the same rule.

The first version (8a8f4ab6) said only that a phrase matching no earlier
commitment is not an action. On three made-up meetings ending in a recap
(gpt-6-luna medium on the LLM Gateway, 2 runs each), it dropped "and Priya
updates the FAQ page by Friday" in 2 of 2 runs; the old prompt kept it. The
revision (bb4b0fe6) keeps a task first given to a named person in the
recap. It got all four probe cases right in 2 of 2 runs: restated tasks,
a new request, a new assignment, and the s4-echo transcript.

## Measured

MeetingsEval on lobsters-mac-mini, notes only (`EVAL_TRANSCRIPTS`), on the
gate (a) transcripts, s3fix's for s3-four-people and three fresh ones for
s3-four-people-echo. Notes on gpt-6-luna medium. M5 judged by Fable.

| Meeting | Gate (a) | First version | Revision (shipped) |
|---|---|---|---|
| ami-ES2004a | 90.3 | 90.3 | 90.7 |
| s1-one-to-one | 94.7 | 94.3 | 95.0 |
| s1-one-to-one-echo | 95.3 | 95.7 | 95.3 |
| s2-three-people | 93.3 | 93.3 | 92.7 |
| s2-three-people-echo | 93.3 | 93.0 | 92.3 |
| s3-four-people | 92.3 (after the audio fix) | 94.3 | 94.7 |
| s3-four-people-echo | 94.0 (fresh baseline) | 94.3 | 94.7 |
| s4-names-unsaid | 93.7 | 93.7 | 92.7 |
| s4-names-unsaid-echo | 60.0 (78.3 in s3fix) | 94.3 | 94.7 |

- No "Set the numbers" item appeared in any run of either version. Kenji
  keeps "by Friday" and Dana keeps "Monday".
- s2-echo and s4-names-unsaid each moved exactly 1.0, the limit. Fable reads
  moves of that size as one judge's noise: the single-run misses behind them
  (Muhammed's "send them to Nihal" dropped, "other vendors in the spring"
  dropped) have no link to recaps.
- One to watch: AMI run 3 listed Sarah's closing aside ("I get to do another
  fantastic PowerPoint presentation") as an action. That is the kind of
  first-time assignment the revision keeps; one run cannot show cause.
- Cost: $0.21 of gateway and transcription calls for both versions and the
  probes.
