# 2026-11-28: Meeting notes: a closing recap restates tasks

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

`MeetingNotesPrompt.rules` has a `recaps` rule under actions, and
`docs/design/meeting-prompt-rulebook.md` has the same rule. It is
c774793b's wording. Set A's first version also scored well but dropped a task
first given to a named person in the recap (the probe below); this wording
keeps it and scored best on the full meetings:

- A closing recap that restates tasks creates no new action. Each recapped
  task matches its earlier commitment and takes the deadline the recap
  states.
- A task the recap gives a named person for the first time is a new action
  for that person.
- A recapped phrase that names no one and matches no earlier commitment is
  not an action.

## How the wording got here

Probes ran on the LLM Gateway (gpt-6-luna medium) against made-up meetings
that end in a recap, 2 runs each, plus the s4-echo transcript.

1. First version (798b6673): a phrase matching no earlier commitment is not
   an action. It dropped "and Priya updates the FAQ page by Friday" in 2 of
   2 runs.
2. Revision (c774793b): keeps a task first given to a named person.
   Measured on 9 meetings × 3 (set C below).
3. 45f035fd: keeps the earlier deadline when the recap states none, and a
   group step (Neon hand read). Neon (agy, Gemini 4 Neon high) then found
   that a first-person commitment made in the recap was dropped and that
   another name read as a handover.
4. 52e73a76 (set D below): added "you'll … restates a task already taken"
   and "scheduling the next call is not an action". s4-echo fell to 83.3,
   with the invented item back in 1 of 3 runs, and the Tuesday follow-up
   meeting disappeared from 5 of 6 s2 notes. Fable 5.2 blocked it: the
   "you'll" clause contradicts the actions and owner rules ("asked to do")
   and is fitted to one mishearing. Both clauses were removed.
5. c81489fd (set E below): c774793b's rule plus the review fixes that
   don't depend on those clauses. Probes, 2 runs each unless noted, all
   right: restated tasks, a new request, a new named assignment ("Priya,
   you'll update the FAQ"), a request first made in the recap, a
   first-person new commitment, sending the invite for the next call, a
   misheard owner, a vague aside, a group step, a recap with no date.
   s4-echo: right in 17 of 18 probe runs, but the probe used only one of the
   three s4-echo transcripts. Scored on all three (set E), the invented item
   was back in 2 of 3 runs, and s4-echo fell to 71.7.
6. Shipped: c774793b's exact wording. On scored runs the two wordings
   without the review additions (sets A and C) had the invented item in 0 of
   6 runs; the two with them (D and E) in 3 of 6. Six runs each cannot prove
   cause, but the full meetings are what users get, and set C meets every
   merge condition: s4-echo 94.7 (main 60.0), no meeting more than 1.0 below
   gate (a), overall 93.6 (gate (a) 88.7). Its known gap, from the probe:
   a recap that names the wrong person for a task already taken ("Omar's
   email" when Mei took it) adds a duplicate task for that person, in 2 of 2
   runs. A first-person new task in the recap ("I'll email legal") is kept
   in 2 of 2.

## Measured

MeetingsEval on lobsters-mac-mini, notes only (`EVAL_TRANSCRIPTS`), on the
gate (a) transcripts, s3fix's for s3-four-people and three fresh ones for
s3-four-people-echo. Notes on gpt-6-luna medium. M5 judged by Fable, 3 runs
per meeting.

| Meeting | Gate (a) | 798b6673 (set A) | c774793b (set C, shipped) | 52e73a76 (set D) | c81489fd (set E) |
|---|---|---|---|---|---|
| ami-ES2004a | 90.3 | 90.3 | 90.7 | 91.0 | 90.0 |
| s1-one-to-one | 94.7 | 94.3 | 95.0 | 95.0 | 93.7 |
| s1-one-to-one-echo | 95.3 | 95.7 | 95.3 | 95.0 | 94.7 |
| s2-three-people | 93.3 | 93.3 | 92.7 | 93.0 | 94.3 |
| s2-three-people-echo | 93.3 | 93.0 | 92.3 | 93.3 | 93.0 |
| s3-four-people | 92.3 (after the audio fix) | 94.3 | 94.7 | 93.7 | 93.7 |
| s3-four-people-echo | 94.0 (fresh baseline) | 94.3 | 94.7 | 93.0 | 94.7 |
| s4-names-unsaid | 93.7 | 93.7 | 92.7 | 94.0 | 94.0 |
| s4-names-unsaid-echo | 60.0 (78.3 in s3fix) | 94.3 | 94.7 | 83.3 | 71.7 |

- The invented "Set the numbers" item: main 5 of 6 runs, set A 0 of 3,
  set C 0 of 3, set D 1 of 3, set E 2 of 3.
- Fable corrected set D after judging set E: s3 93.7 and s3-echo 93.0 (a
  missed $4,000 estimate). Overall stays 92.4.
- Not measured: main's #146 rewrote the LANGUAGE rule after these runs. The
  merge is clean, but the merged prompt has not been scored.
- Follow-ups, none blocking:
  - The misheard-owner duplicate above is an old gap: main without the rule
    also duplicates it, 2 of 2 on the same probe.
  - Read to the letter, the last sentence would drop a first-person task or
    a group step first made in the recap, since neither names a person. The
    general action rules keep them: the probe kept "I'll email legal" in 2 of
    2, and set C kept the s2 follow-up meeting in 4 of 6 and AMI's group step
    in 3 of 3.
  - The rule doesn't say an earlier deadline stays when a recap repeats a
    task without one; the deadline rule should hold it, untested.
  - Probe with all three s4-echo transcripts before any further change.
- The rule was written for s4-names-unsaid-echo, a scored meeting, so its
  gain there is expected; the other eight meetings and the probes are the
  evidence it generalises.
- One to watch: AMI run 3 of set C listed Sarah's closing aside ("I get to
  do another fantastic PowerPoint presentation") as an action.
- Cost: about $0.40 of gateway calls for all versions and probes.
