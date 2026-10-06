# OpenAI dictation without whisper-1

2026-10-06. Shipped in 0.5.17 (42).

## Why

The owner asked for OpenAI dictation to use only its transcription model
(`gpt-transcribe`) and its writing model (`gpt-6-luna`). Since 2026-09-28
every single-chunk OpenAI dictation with writing rules on also sent the audio
to `whisper-1`. That transcript went into the cleanup prompt as SECOND so
GPT-6 Luna, which cannot hear audio, could repair misheard words.

## What changed

- Removed `OpenAIConfig.secondOpinionModel`,
  `GeminiClient.secondOpinionTranscript`,
  `GeminiTranscriptionService.awaitSecondOpinion`, the parallel task that
  called them, and the `second` parameter of the cleanup pass.
- Removed `PromptV1.secondTranscriptSection` and the `secondTranscript`
  parameter of `PromptV1.cleanupPrompt`. The prompt now ends with the field
  context (when present), then `RAW:`, on both providers.
- `openAIMessages` no longer looks for a `SECOND:` label when it splits the
  prompt around screenshots.
- Kept `whisper-1` in `PriceBook.perMinute` and the `whisper` prefix in
  `ModelProvider.openAI.modelPrefixes`, so usage rows booked by older builds
  still have a price and still show on the OpenAI Cost tab.
- Docs: README, PRIVACY (audio no longer goes to a second OpenAI model),
  COST_TRACKING, AGENT-MODE.

## Tradeoff

The 2026-09-28 measurement (22 of 22 misheard stretches repaired with SECOND)
no longer applies. A word `gpt-transcribe` mishears now stays misheard unless
the writing rules' sound-alike and context repairs catch it. In exchange, each
OpenAI dictation makes one fewer call, costs $0.006 per audio minute less, and
long dictations no longer wait up to 5 s for the second transcript.

## Verification

- `scripts/test.sh`: 143 tests passed. `scripts/build-ios.sh` succeeded.
- `scripts/release.sh` built, signed and notarized 0.5.16 (Accepted,
  stapled), installed to /Applications. The binary no longer contains the
  SECOND prompt text.
- On OpenAI, Retry Transcription on an 8 s History recording booked exactly
  two calls: `gpt-transcribe` ($0.00045) then `gpt-6-luna` ($0.00008). No
  `whisper-1` call. The result read "Build the signed and authorized
  application…"; the speaker said "notarized", which is the kind of mishearing
  SECOND used to repair. The provider was set back to Gemini afterwards.
