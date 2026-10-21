# 2026-10-21: Cleanup timeout on the MacBook, and a pill notice for the local fallback

## Incident

A 107 s dictation on the MacBook at 07:07 IST (History row
`01B03112-5AA4-48BD-8D32-76486DAFAA02`, 993 characters, target Amp) was
inserted with "Writing rules skipped: cleanup timed out; filler words
removed". The unified log on the MacBook keeps no `io.blue.voiceiq` lines
for that window, so the evidence is `transport.jsonl` and `history.sqlite`
under `~/Library/Application Support/VoiceiQ/`.

`transport.jsonl` shows both cleanup attempts to `api.openai.com`
(`gpt-6-luna`, provider OpenAI):

- 01:39:29Z attempt 1: connect 29 ms, h2, 38 084 request bytes sent, no
  first byte, `timeout` after 14 850 ms.
- 01:39:36Z the fresh retry (started 6.7 s in, as
  `freshRetryTiming` sets for a 14.8 s deadline): connect 47 ms, h2, same
  bytes sent, no first byte, `timeout` after 14 859 ms.

The deadline was `cleanupDeadline(forCharacters: 993)` = 12 + 993/350 =
14.8 s. The TCP and TLS handshakes succeeded in under 50 ms each, so the
network was up and the request reached OpenAI. OpenAI did not start
answering within the budget on either connection. The next dictation's
cleanup at 01:42:52Z got its first byte after 12.6 s against a 2 to 4 s
baseline earlier that morning, so the provider was slow in that window.
The pipeline took 23.1 s because the second attempt ran to its own
deadline after the first expired.

Verified: both attempts timed out with no response bytes while the
connections were healthy. Inferred: a provider-side latency spike, from
the 12.6 s first byte of the next request. The 14.8 s budget is also
tight for a 38 KB prompt on a slow day; the budget formula is unchanged
here.

## What changed

- `TranscriptionResult.cleanupNote: String?` became
  `cleanupSkip: CleanupSkip?` (`Services.swift`). `CleanupSkip` names the
  cause (`shortDictation`, `requestFailed`, `rewriteRejected`), whether
  `FillerStripper` ran, and the History note. `cleanupNote` is now a
  computed property over it, so History, the retry queue, and the recovery
  scanner keep writing the same `errorMessage`.
- `GeminiTranscriptionService+Cleanup.settle` fills the cause and the
  filler flag; the short-dictation skip in `GeminiTranscriptionService`
  uses `.shortDictation`.
- `DictationCoordinator.lastCleanupSkip` is set beside `lastResult`.
- `DictationController.handleOutcome(.inserted)` shows a 4 s pill notice
  (`cleanupFallbackNotice`) in place of the tick when the cause is a
  failed request or a rejected rewrite: "Cleanup request failed — filler
  words removed locally", "Cleanup request failed — inserted as spoken",
  or the "Cleanup rewrite rejected — …" pair. The success earcon still
  plays because the text was inserted. A short dictation kept as spoken
  shows the normal tick. The clipboard, chip, secure-field, and queued
  outcomes keep their own notices, which tell the user what to do next.

## Verification

Notarized 0.6.2 build (`SKIP_TESTS=1 scripts/release.sh`, staple and
`spctl` accepted) installed to `/Applications` on the Mac mini. The
cleanup failure was forced with `cleanupModelOverride =
gemini-does-not-exist` (Gemini answers 404 in about 0.5 s, so the
`requestFailed` path runs without waiting out a deadline). Speech came
from `say` through the Jump Desktop loopback mic; the pill was read
through its accessibility tree and screenshots every 0.4 s.

- Verbatim transcription, a transcript with "um" and "uh": the pill
  showed "Cleanup request failed — filler words removed locally" for six
  frames (about 4 s) and then the resting dot. TextEdit received the
  transcript with the fillers removed. The History row's details read
  "Writing rules skipped: cleanup failed (modelUnavailable(...)); filler
  words removed".
- Smart transcription, no fillers: "Cleanup request failed — inserted as
  spoken" for six frames.
- Control with the override removed: cleanup succeeded on
  `gemini-3.8-flash` and the pill showed "Inserted 19 words" as before.

The rejected-rewrite wording was not driven; it shares the code path
with the two notices above and differs only in the leading words. Test
prefs were deleted afterwards and the app relaunched.
