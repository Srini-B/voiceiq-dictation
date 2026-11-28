# 2026-11-28: A meeting interrupted while writing notes fails at launch

## Why

Neon's review of #132 (agy, session 501c170e): a meeting the app quit on, or
that iOS ended in the background, while it was transcribing or writing notes
stayed `.summarizing` or `.transcribing` at the next launch, with no Retry:
"Making notes" on the Mac and an endless "Writing notes" on iPhone. Only
recordings and meetings waiting for AssemblyAI were failed at launch. With
notes at effort medium (#132) the notes step takes 40 s to several minutes
instead of about 7 s, so this became likely.

## What changed

- `MeetingEngine.failInterruptedRecordings` fails every meeting left in
  `.recording`, `.transcribing` or `.summarizing` at launch as
  `failed("interrupted")`. One that was writing notes gets
  `failedStep = .notes`, so Retry writes only the notes from the saved
  transcript. Only finished meetings sync, so a meeting another device is
  still writing up is never in this store.
- From the same review: a reply cut off at max_tokens
  (`output_truncated`) is not a connection failure, so dictation doesn't send
  a second, equally doomed request; meeting chat says the answer ran past the
  model's length limit instead of "Couldn't reach AssemblyAI".

## Verification

CI (`swift test`, App and iOS builds);
`MeetingRenameTests.testAMeetingInterruptedWhileWritingUpFailsAtLaunch`.

## Long-meeting notes on the LLM Gateway (probe)

Neon's review of #132 asked whether a 1–2 hour meeting's notes at effort
medium outrun the gateway's limits on a non-streaming request. One request at
the app's settings (gpt-6-luna, strict notes schema, max_tokens 32,000) with
a synthetic 120-minute transcript (714 turns, 23,437 input tokens) from this
orb, 2026-11-28 (`.amp/in/orb-backup/long_notes_probe.py`):

| Effort | Time | Output tokens | Result |
|---|---|---|---|
| medium (shipping) | 38.2 s | 4,771 | notes JSON, 14 actions |
| high | 83.7 s | 10,586 | notes JSON, 14 actions |

No gateway cut-off at 84 s, and the shipping setting used 15% of
max_tokens and 4% of the 900 s notes deadline. The gateway reports
`reasoning_tokens: 0` in usage at both efforts, so reasoning is not broken
out. A real 2-hour call's transcript may run longer than this synthetic one.
