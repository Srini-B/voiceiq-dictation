# Transcribe first, then clean up

2026-10-05. Local, uncommitted at the time of writing.

## Why

Since 0.5.0 (2026-09-28), a Gemini dictation with writing rules on and under
ten minutes skipped `gemini-3.5-transcribe`. One `gemini-3.8-flash` call heard
the audio and wrote the cleaned text. The owner wants the transcription model
to run on every dictation, with the writing model cleaning its transcript.
The writing-rules toggle must not change which model transcribes.

## What changed

- Every dictation now runs `gemini-3.5-transcribe` or `gpt-transcribe` first.
  With writing rules on, `gemini-3.8-flash` or `gpt-6-luna` then cleans RAW.
- Screenshots still go only to the writing model.
- OpenAI keeps `whisper-1` as SECOND for single-chunk dictations.
- Removed the one-call path and the code only it used:
  `transcribeInOneCall`, `PromptV1.dictationPrompt`, `dictationSchema`,
  `dictationText`, `noSpeechToken`, `ModelProvider.writingModelHearsAudio`,
  the `audioFLAC` and `jsonSchema` parameters of `GeminiClient.cleanup`, and
  the `speechHeard` gate (`DictationContext.speechHeard`,
  `NoiseFloorEstimator.samplesAboveFloor`).

## Trade-off

Gemini dictations get slower. Measured 2026-09-28 on a 21 s dictation:
2.4 s for the one call, 7.5 s for transcription then cleanup.

## Verification

- `swift test` in `VoiceIQCore`: 143 tests, 0 failures.
- macOS and iOS Debug builds compile.
- Not yet tested on a signed, notarized build.

## Rollback

Revert this change. The one-call path returns as it was in 0.5.15.
