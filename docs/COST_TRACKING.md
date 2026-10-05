# Cost tracking

VoiceiQ meters every model call, Gemini and OpenAI, and shows the result under
Settings → Cost Analysis (`voiceiq://settings/cost`) and per dictation in
History. Costs are in US dollars.

## What is recorded

Each successful model call becomes one `UsageRecord` in
`~/Library/Application Support/VoiceiQ/usage.sqlite` (GRDB, WAL). Fields:
time, activity, stage, model, session ID, token counts by modality (text,
audio, image, cached in; text, audio, thought out), an `isEstimated` flag,
`costUSD`, and `audioSeconds`. The table also has `fxRateINR`, `fxDate`
(migration `v3-fx`) and `listINR` (migration `v4-listINR`) from the removed
Sarvam integration. The migrations stay registered so existing databases keep
a known history, but nothing reads or writes those columns.

`audioSeconds` is the audio a call was billed for, on models priced by audio
length (OpenAI's transcription models). It comes from the response when it
states the length (OpenAI's `usage.seconds`), otherwise from
`UsageMeter.audioSeconds`, a task-local that
`GeminiTranscriptionService.sendTranscribe` sets to the length of the audio it
sends. `UsageMeter.record` applies
it only to calls that report no tokens. The column was added in migration
`v2-audioSeconds`; per-minute calls booked before it have no length.

Activities: `dictation`, `askAnything`, `translate`, `meeting`, `agent`,
`other`. Stages: `liveTranscribe`, `transcribe`, `cleanup`, `answer`,
`translate`, `webQuery`, `meetingTranscribe`, `meetingSummary`, `agentStep`.

Agent mode records one `agentStep` per model call. Its transports
(`AgentEngine/AgentTransport+*.swift`) do not go through `GeminiClient.post`;
each parses its own usage envelope with `TokenUsage.fromOpenAI`,
`fromOpenAIResponses`, `fromAnthropic`, or `fromGenerateContent` and calls
`UsageMeter.record(stage: .agentStep, …)`. The session ID is the agent
session's UUID, so a whole session can be summed. Cached input tokens land in
the cached-in column when the host reports them. See `docs/AGENT-MODE.md`.

The ledger is separate from `history.sqlite` so deleting a dictation or its
audio never changes what it cost.

## Where the counts come from

`GeminiClient.post` is the only REST transport for both providers, so it is
the one place that reads usage on a 200. On Google's endpoint two
envelopes are handled by `TokenUsage`:

- `:generateContent` → `usageMetadata` (`promptTokensDetails`,
  `candidatesTokensDetails`, `thoughtsTokenCount`, `cachedContentTokenCount`).
- `v1beta/interactions` → `usage`. `total_output_tokens` came back 0 while
  `model_invocation_token_counts` carried the real output count (probed
  2026-09-26), so the per-invocation list is authoritative.

The live socket (`LiveTranscriptionSession`) reads `usageMetadata` frames as
they arrive and books the largest total at `finish()`. If no frame carried
usage, it estimates: audio seconds × 25 tokens/s for the transcribe models
(32 for other models) and output characters ÷ 4, flagged `isEstimated`.

On OpenAI's own API, the transcription models (`gpt-transcribe`,
`gpt-4o-transcribe`, and `whisper-1`, which each OpenAI dictation with writing
rules also sends for a second transcript) bill per audio minute and report
`usage: {type: "duration", seconds}`; `TokenUsage.fromOpenAIDuration` books
`seconds / 60 × PriceBook.perMinutePrice` as `reportedCostUSD` with no token
counts. Chat models (GPT-6 Luna, and
`gpt-4o-transcribe-diarize`, which bills tokens) use the OpenAI-shaped
`usage` block (`TokenUsage.fromOpenAI`).

## Attribution

`UsageMeter.scope` is a task-local `UsageScope(activity, sessionID)`. It is set
around the dictation finalize task in `DictationCoordinator`, the retry queue's
transcribe, and `MeetingEngine` processing.
Calls without a scope are booked as `other`.

## Pricing

`PriceBook` holds paid-tier Standard prices per million tokens from
ai.google.dev/gemini-api/docs/pricing (copied 2026-09-26) and Standard prices
from developers.openai.com/api/docs/pricing (copied 2026-09-28; GPT-6 Luna,
GPT-6 Sol, `gpt-4o-transcribe-diarize`, plus the per-minute table for the
transcription models), matched by the longest model-ID prefix. A `google/` or
`openai/` prefix, found on rows booked through the gateways older builds
supported, is removed first. Gemini 3.8 Flash doubles on 2027-01-01 and the book
switches on that date. Models without an entry are stored with `costUSD = nil`
and shown as unpriced; totals that include an unpriced or estimated call show
a ≈ prefix.

The app cannot tell whether a Gemini key is on the free tier, so it always
shows the paid-tier figure.

## UI

`CostPane` shows one provider at a time. It opens on the provider selected in
Settings → Advanced, and a Gemini/OpenAI toggle (`CostSource`) switches to the
other; every read filters `usage` rows by model ID
(`CostSource.modelPrefixes`: `gemini` and `google/` for Gemini, `gpt`,
`whisper` and `openai/` for OpenAI). Rows from services older builds supported
(ElevenLabs, MAI Transcribe 2, Sarvam) match neither tab. It shows today, this
week, this month, and all time totals; a period picker drives the by-action
and by-model tables and the recent-calls list. The footer names the price
source (`CostSource.pricingNote`): the provider's pricing page. The iPhone's
Cost page has the same source toggle.
`HistoryPane` shows the summed session cost on each row and the detail sheet
lists each call with its model, what it was billed on, and its cost.

`UsageFormat.measure` writes what a call was billed on: "in 1.2k · out 300"
for token-priced calls, "6m 30s of audio" for audio-priced ones, and "billed
by audio length" for audio-priced calls booked before `audioSeconds` existed.
History, the recent-calls lists on both platforms, and the iPhone's breakdown
rows use it. The Mac's detailed breakdown tables have Tokens in, Tokens out,
and Audio columns, with "—" where a row has none.
