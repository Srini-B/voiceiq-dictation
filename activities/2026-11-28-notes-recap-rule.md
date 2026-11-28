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

The first version (798b6673 in the PR) said only that a phrase matching no earlier
commitment is not an action. On three made-up meetings ending in a recap
(gpt-6-luna medium on the LLM Gateway, 2 runs each), it dropped "and Priya
updates the FAQ page by Friday" in 2 of 2 runs; the old prompt kept it. The
revision (bb4b0fe6) keeps a task first given to a named person in the
recap. It got all four probe cases right in 2 of 2 runs: restated tasks,
a new request, a new assignment, and the s4-echo transcript.

Review found gaps in the revision, fixed in the final wording:

- Neon hand read: a group step agreed in the recap was dropped, and a recap
  with no deadline could clear the earlier one.
- Neon (agy, Gemini 4 Neon high, at 45f035fd): a first-person commitment
  first made in the recap could be dropped; a recap that names a different
  person read as a handover; "group action" was undefined.

The final wording keeps the earlier deadline when the recap states none and
the earlier owner unless that person agrees to take the task; counts a new
task only when it is a first-person commitment or given to a named person;
reads "you'll …" in a recap as restating a task already taken; makes a
concrete group step an action with owner null; and never makes scheduling
the next call an action. An intermediate wording that keyed new tasks on
"asked to do" brought back s4-echo's invented item ("You'll set numbers…"
read as a request), in 2 of 2 and then 1 of 2 runs, so it was dropped.

LLM Gateway probe of the final wording (gpt-6-luna medium): s4-echo right in
6 of 6 runs; restated tasks, a new request, a new named assignment, a
first-person new commitment, a misheard owner, a vague aside, scheduling the
next call, a group step and a recap with no date each right in 2 of 2.

## Measured

MeetingsEval on lobsters-mac-mini, notes only (`EVAL_TRANSCRIPTS`), on the
gate (a) transcripts, s3fix's for s3-four-people and three fresh ones for
s3-four-people-echo. Notes on gpt-6-luna medium. M5 judged by Fable.

| Meeting | Gate (a) | First version | Revision (c774793b) |
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
- The rule was written for s4-names-unsaid-echo, a scored meeting, so its
  gain there is expected; the other eight meetings and the probes are the
  evidence it generalises.
- One to watch: AMI run 3 listed Sarah's closing aside ("I get to do another
  fantastic PowerPoint presentation") as an action. That is the kind of
  first-time assignment the revision keeps; one run cannot show cause.
- Cost: $0.21 of gateway and transcription calls for both versions and the
  probes.
