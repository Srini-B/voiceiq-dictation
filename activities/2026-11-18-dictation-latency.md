# 2026-11-18: Dictation latency (6 s → 3 s target)

## Why

Dictation on cyron's MacBook (0.7.8) took about 6 s from key-up to inserted text. The target is 3 s or less.

## Measured on the MacBook (37 dictations, 2026-11-12 to 11-18, read-only export)

All of them used ElevenLabs Scribe v3 in smart mode, with OpenAI gpt-6.1-terra as the writing model. Screen context was on.

| Layer | With cleanup (30): avg / p90 | Cleanup skipped, ≤5 s (7): avg / p90 |
| --- | --- | --- |
| Key-up → done | 5.74 / 7.59 s | 1.85 / 2.21 s |
| Finalize (trailing capture + teardown) | 0.23 / 0.39 s | 0.23 / 0.48 s |
| FLAC encode | 0.03 s | 0.01 s |
| Scribe request (connect 90 ms) | 2.17 / 2.81 s | 1.48 / 1.61 s |
| Writing request (connect 42 ms, 186 KB, ~9,900 tokens in, ~47 out) | 3.12 / 4.22 s | n/a |
| Insert (AX insert, then ⌘V fallback in 30 of 37) | 0.13 s | 0.12 s |

No model request was retried or switched to a fallback provider; the ⌘V fallback above is the insertion step. Every request opened a new connection.

## Measured from an orb in Oregon (2–6 runs each, same request shapes as the app)

- Scribe transcript_edit adds 0.27–0.91 s per request (medians: no edit 0.63/0.80/0.94 s vs edit 1.08/1.71/1.20 s on 3/11/22 s clips).
- OpenAI live transcription final, after commit: 0.43–0.70 s.
- gpt-6.1-terra with the full 36.6k-character prompt: 1.7–2.8 s (median). Adding a screenshot adds ~0.2–0.8 s. A 4.5k-character prompt was not faster, because the long prompt is cached.
- gpt-6-luna takes 0.8–1.4 s. On the 22 s email it dropped the numbered list and email layout that Terra produced.

- ElevenLabs Scribe v3 Live with `commit_strategy=manual` returned `committed_transcript` 64–141 ms after the commit, on 3–22 s clips streamed in real time. An empty audio chunk with `commit: true` commits what was sent. Despite `manual`, the server committed by itself at 35.2 s of uncommitted audio (67 s stream); with a client commit every 30 s, it sent exactly one `committed_transcript` per client commit (3 of 3). So the dictation stream rolls its turn after 25 s at a pause and at 30 s at the latest.

## Screen context: benefit vs cost

- **A/B test:** 9 scenarios, 81 gpt-6.1-terra calls, with real Scribe output as RAW and 2 hand-made variants. The screenshot fixed 20 of the 23 on-screen term misspellings the run without it left wrong (87%), for example Joaquín, VoiceiQ, Oluwaseun, Siobhán and `~/Library/Logs/VoiceiQ`.
  - It changed no output format.
  - Nothing leaked into the text in 81 outputs, and no near-miss name was swapped.
  - It added about +1.2k prompt tokens and about +0.9 s median.
  - The window title alone already fixes terms that appear in it.
- **cyron's real 30 cleanup dictations:** only 5 (17%) gained a term that the Dictionary doesn't explain, all in Amp. Most were digits or acronym joins, and only 1 was a new capitalized name. That puts the realistic benefit at about 1–3 in 30 dictations.
- **Recommendation:** keep it off by default (it already is). Turn it on only when names on screen matter more than about 0.5–0.9 s per dictation.

## Changed (cyron's decisions, shipped with 0.7.9)

- **Real-time transcription:** the existing toggle now also streams with Scribe v3 Live while ElevenLabs transcribes, on macOS only (`ElevenLabsLiveDialect`). It stays off by default, as the owner chose on 2026-11-10. A failed stream falls back to the batch upload.
- **Scribe's formatting edit (`transcript_edit`):** removed in every case, including dictations of 5 s or less. There is no toggle.
- **Faster writing model (GPT-6 Luna):** prototyped, then dropped. cyron doesn't want a faster writing tier.
- **Screen context:** unchanged, off by default. Its description now states the cost.
- **Timing:** new debug-log lines, `[transcription] timing: …` and `[session] timing <id>: …` (docs/DEBUG_LOG.md).

Not measured: real dictation on a signed build. The installed app needs keys and someone speaking.
