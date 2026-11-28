# Far-side naming by address, in code (2026-11-28)

## Why

Gate (a) on AssemblyAI (main 671a680, then PR #127) left the far side of the
synthetic gallery calls unnamed: s2 and s2-echo never named Nihal or Muhammed
Hafeed, and s3 and s3-echo swapped between fully named and half named from one
run to the next with the same words. Every M4 of 0 came from naming; the
speaker splits were right. In a gallery call every tile is on screen all the
time, so `ScreenSpeakerNames.match` cannot tell who talked, and the names had
to come from the notes model (gpt-6-luna on the LLM Gateway) applying the
prompt's single-address rule. It did so unreliably.

## What changed

`ScreenSpeakerNames.byAddress` runs after `match`, before the notes, in
`MeetingEngine` and in MeetingsEval:

- A sentence that opens with an invitee's or on-screen name and a comma
  ("Sara, you first.", "Muhammed, where are we…") is an address. "Thanks
  Alex." and "Fair point Grace." are not.
- The next turn by a different far-side voice is that person's answer. A voice
  answering two names, or a name answered by two voices, names nobody.
- Then the last voice is named by elimination, so the notes are written once
  with every name.

## Verification

Unit test on the s3 opening and on s2's first-name address; Mac mini
`swift test`; MeetingsEval on the synthetic set with the earlier transcripts
(`EVAL_TRANSCRIPTS`), so no new transcription spend.
