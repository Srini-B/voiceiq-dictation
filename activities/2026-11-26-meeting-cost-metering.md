# 2026-11-26: Meeting eval measures cost; notes replies are schema-bound

## Why

cyron's standing rule: Gemini cost for dictation and meetings together stays
under ₹250 a month at about 160 dictations and 4 meeting hours (scorecard C1).
The cost study estimated about ₹40.7 per meeting hour, of which notes were
estimated, not measured. Every meeting PR now reports cost per meeting hour.

## What changed

- `eval/meetings` records every Gemini call a meeting makes through the app's
  own `UsageMeter` and `PriceBook`, and writes the calls, the total and the cost
  per hour into each output. Duration is the longer of the two tracks.
- The notes request sends a `responseSchema`
  (`GeminiClient.notesSchema`). With JSON mode alone, gemini-3.8-flash wrote
  stray text inside the object (`"…Wednesday." his? wait, strictly no unneeded
  text]`, `…Wednesday." hackers]: null`). Each such reply cost a second notes
  request, and once both failed and the meeting had no notes.

## Verification

Notes only, from saved transcripts of the eight synthetic calls, three runs
each:

- JSON mode alone: 3 retries for unparseable replies in 24 meetings. In
  separate probes, 5 bad replies in about 40, and one meeting failed outright.
- With the schema: no retries in 24 meetings. Each meeting had the same number
  of action items as before (s2 4 or 5, s3 4). s4 still makes 2 calls by design,
  because the notes are rewritten after elimination.
- A notes call on a 70-second call costs about $0.004 (about 3,500 input and
  400 output tokens). The cost per meeting hour, transcription included, needs
  a run on AMI. The AMI download mirror returned HTTP 503 and the Gemini
  transcription quota was spent on 2026-11-26.
- The eval prices every call at January 2027 prices (2027-01-02), the prices
  the C1 gate uses; gemini-3.8-flash doubles then. At those prices, one notes
  call on a 70-second call costs about $0.008 to $0.011.

## Tried and not kept: the Flex tier for notes

Gemini's Flex tier (`serviceTier: "flex"`, half price, latency of minutes) was
tried for the notes request, with the standard tier as fallback. Every one of
18 Flex requests on 2026-11-26 came back `http_503` (no capacity). One hung
until the 300 s deadline before the fallback ran. Flex saved nothing and added
up to five minutes to the notes, so it is not shipped. It is worth trying again
when Flex capacity is reliable.
