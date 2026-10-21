# 2026-10-21: English tools replay, VAD removed for Fluid Speech Mini, iOS deadline

## Why

The user reported that dictation with English tools on felt less accurate
and slower than without, and that the iOS app once stayed on "transcribing"
with the pack on. The question was whether we use the pack the way
FluidVoice does.

## What FluidVoice does (altic-dev/FluidVoice, source read 2026-10-21)

- macOS only. The README says iOS is "on the way". There is no English tools
  equivalent on an iOS app because there is no iOS app.
- No Silero VAD in the dictation to Parakeet path.
- Vocabulary boosting goes through FluidAudio `configureVocabularyBoosting`
  on a separate final-only ASR manager, only when the dictionary is
  non-empty, never on the streaming manager (a comment cites CTC and ANE
  SIGTRAP crashes).
- Parameters: alpha 2.8, minCtcScore -2.2, minSimilarity 0.72,
  minCombinedConfidence 0.64, minTermLength 3, up to 256 terms. FluidAudio's
  own defaults scale with dictionary size (cbw 1.75 to 3.0, minSimilarity
  0.72 to 0.85).

## What we did before this change

The pack is Silero VAD plus Parakeet CTC 110M. On every Fluid Speech Mini
final decode the VAD trimmed silent edges, then (with a non-empty
dictionary) CTC spotting and `ctcTokenRescore(cbw: 0, minSimilarity: 0.75,
spotterRescueEnabled: false)` wrote corrections into the normalized
candidate only.

## Measurement

15 real dictations from `.amp/in/asr/eval` (cloud transcripts as references),
the 100-term user vocabulary, the notarized helper on an M2 Mac mini,
`.amp/in/english-tools/replay.py`. WER is on the original transcript unless
noted; times are the helper's transcribe step.

| Condition | WER | Transcribe, all 15 | Notes |
|---|---|---|---|
| No pack | 13.4% | 5.0 s | |
| Pack, empty dictionary (VAD trim only) | 13.8% | 5.5 s | Two clips trimmed, both worse: 8BA149BF 7% to 10%, BC66A957 19% to 21%. None improved. |
| Pack plus dictionary | 13.8% original, 14.1% normalized | 16.8 s | Plus 14.7 s one-time CTC compile on first load, 0.28 s after. |

The tail trim on the two clips changed words and casing in the middle of
the sentence, not at the edge. The CTC pass costs about 0.3 to 0.5 s per
dictation plus about 0.02 s per audio second (30 s clip 0.2 s to 1.0 s,
118 s clip 1.2 s to 3.8 s).

Dictionary rescoring made 8 replacements: "super base" to "Supabase",
"codux" to "Codex", "Ahili" to "Aheli", "code base" to "codebase" were
right; "MCPs" to "MCP" and "left" to "EFT" were wrong. Normalized WER with
the dictionary (14.1%) against VAD only normalized (14.3%) is a small net
gain from CTC itself.

## Decisions

- Fluid Speech Mini no longer loads or runs the VAD
  (`EnglishTools.load(speechDetection: false)` from `ParakeetSession`).
  The replay showed no clip it helped and two it hurt, and it cost about
  0.5 s. Nemotron file mode keeps its trim and the streaming meter; those
  paths were not measured here.
- Rescorer parameters stay at cbw 0, minSimilarity 0.75, rescue off. The two
  wrong replacements pass FluidVoice's 0.72 and FluidAudio's 0.85 similarity
  as well (0.857), so copying their values would not fix them.
- English tools stay offered on iPhone and iPad.
- The settings note no longer mentions speech detection.

## iOS "stuck on transcribing"

Verified by code, not reproduced on a device. On iOS `LocalTranscriber.finish`
ran the in-process session's load and transcribe with no deadline, and
`DictationCoordinator` awaited it without one. The Mac helper has 120 s for
load and `max(120, 2 × duration)` for transcribe, after which the helper is
killed and the saved recording goes to cloud. The first CTC load compiles
the model (14.7 s on this Mac, longer on a phone), which fits a long stall
with the pack on, but the missing deadline is the only verified cause.

Change: `TimeoutPolicy.localLoad` and `localTranscribe(frames:)` hold the
shared numbers; `LocalSpeechHelper` uses them and `LocalTranscriber.finish`
races the in-process work against their sum. On timeout it logs, releases
the session, lets `worker.stop()` join the Core ML work in a detached task,
and returns nil so the coordinator uses the saved audio with cloud
transcription. Core ML work cannot be cancelled, so the stalled work keeps
running until it ends on its own.

## Verification

- `swift build` and `swift test` in `VoiceIQCore`: 143 tests, 0 failures.
- Replay of the same 15 dictations on the notarized 0.6.2 (47) build with
  the VAD removed (`.amp/in/english-tools/results-novad.json`):

| Condition | WER original | WER normalized | Transcribe, all 15 | Load, all 15 |
|---|---|---|---|---|
| No pack | 13.4% | | 5.0 s | 2.6 s |
| Pack, empty dictionary | 13.4% | 13.8% | 4.9 s | 2.1 s |
| Pack plus dictionary | 13.4% | 14.1% | 15.9 s | 3.9 s |

  The pack with an empty dictionary now produces the same original
  transcript as no pack on every clip. The dictionary pass is the whole
  remaining cost. Its replacements on this run: right "super base" to
  "Supabase", "codux" to "Codex", "code base" to "codebase", "Ahili" to
  "Aheli" (the cloud reference spells it "Ahili", so WER counts it as an
  error); wrong "MCPs" to "MCP", "left" to "EFT", and three "window",
  "window is", "window," to "Windows" in one clip (the first run's
  replacement list missed this cluster). Net, the dictionary pass adds 2
  errors over 659 words on these references; it is left on because the
  candidate only reaches the writing model as evidence, and it fixes the
  product names the dictionary exists for. Whether to keep it is the
  user's call.
- iPad Air 11-inch (M4) simulator, Release build: Settings, Dictation shows
  the Fluid Speech Mini and English tools rows with the new note
  (`.amp/in/artifacts/ipad-dictation-on-device.png`).

## Gaps

- No physical iPhone or iPad test of the deadline or the pack.
- The iOS in-process meeting path (`LocalMeetingTranscriber` through
  `LocalSpeechInference.transcribeMeeting`) has no deadline. The Mac
  `LocalMeetingHelper` has `max(600, 3 × duration)`.
- An abandoned in-process session is no longer tracked by `LocalModelStore`,
  so deleting the model while that work still runs does not wait for it.
