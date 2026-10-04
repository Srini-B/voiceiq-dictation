# Cost tracking

VoiceiQ meters every model call, Gemini and OpenAI, and shows the result under
Settings → Cost Analysis (`voiceiq://settings/cost`) and per dictation in
History. The pane shows dollars or rupees.

## What is recorded

Each successful model call becomes one `UsageRecord` in
`~/Library/Application Support/VoiceiQ/usage.sqlite` (GRDB, WAL). Fields:
time, activity, stage, model, session ID, token counts by modality (text,
audio, image, cached in; text, audio, thought out), an `isEstimated` flag,
`costUSD`, `audioSeconds`, the rupee rate of the call's day (`fxRateINR`,
`fxDate`; migration `v3-fx`), and `listINR` for rupee-priced models
(migration `v4-listINR`).

`audioSeconds` is the audio a call was billed for, on models priced by audio
length (ElevenLabs Scribe, OpenAI's transcription models, MAI Transcribe 2).
It comes from the response when it states the length (`audio_duration_secs`,
OpenAI's `usage.seconds`), otherwise from `UsageMeter.audioSeconds`, a
task-local that `GeminiTranscriptionService.sendTranscribe` and MAI meeting
windows set to the length of the audio they send. `UsageMeter.record` applies
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

`GeminiClient.post` is the only REST transport for every provider and gateway,
so it is the one place that reads usage on a 200. On Google's endpoint two
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

ElevenLabs Scribe returns no usage block, so `GeminiClient.elevenLabsTranscribe`
books each batch call itself (`post` skips it for `.elevenLabs`): the
response's `audio_duration_secs`, or the chunk's length when that field is
missing, at `scribe_v2`'s $0.22 an hour, plus
`PriceBook.elevenLabsKeytermsPerMinute` ($0.05 an hour) when dictionary terms
were sent as `keyterms`. Prices are from
elevenlabs.io/pricing/api (copied 2026-09-28) and are the same on every plan;
hours included in a subscription are not subtracted, so the pane shows list
price.

MAI Transcribe 2 runs through OpenRouter or Vercel AI Gateway, and both report
the charge for each call (`usage.cost`, or `providerMetadata.gateway.cost` on
Vercel), so nothing is priced locally. Both list it at $0.10 an hour (checked
2026-10-02). Its records are stored under `microsoft/mai-transcribe-2` and the
Cost pane shows them under MAI.

Sarvam prices in rupees and returns no usage on speech calls.
`GeminiClient.sarvamTranscribe` and `sarvamDiarize` book the length of the
audio sent (`TokenUsage(audioSeconds:)`) under `saaras:v4`, or
`saaras:v4:diarize` for a meeting job with speaker labels; `PriceBook.perMinuteINR`
holds ₹30 and ₹45 an hour. `sarvam-105b` chat calls carry an OpenAI-shaped
`usage` block and are priced from `PriceBook.pricesINR` (₹29.28 in, ₹10.98
cached, ₹73.20 out per million tokens). Prices are from
docs.sarvam.ai/api-reference-docs/pricing (copied 2026-10-03). A rupee price
becomes `costUSD` at the rate stored on the row (below); until the rate is
known the row is unpriced.

## Rupees and the exchange rate

Every row stores INR per USD for its day (`fxRateINR`) and the quote's date
(`fxDate`). The rate comes from Frankfurter (`api.frankfurter.dev/v1`, the
European Central Bank reference rate, published on business days), with no
key. `FXRates.refresh` fetches `latest?base=USD&symbols=INR` at launch, when
a Sarvam call (speech or chat) starts, without waiting for it, and whenever a
row is booked without a rate, and caches the quote in `UserDefaults` (`fxQuoteINR`) for
four hours. `UsageMeter` runs one refresh-and-backfill at a time. `UsageRecord.init` uses
the cached quote only if it was fetched on the call's UTC day; otherwise the
row waits, so a quote from the evening before never prices a morning call.

`UsageStore.backfillFX` finds rows with no rate, asks Frankfurter for one
range in one request (`/v1/{start}..{end}`, from the first of a month at
least 31 days before the oldest such row through today) and writes each row
the rate of its own day, or the nearest earlier business day for a weekend or
holiday. The range is the only thing the request says about the ledger; it
is deliberately coarser than the rows' own days (see `docs/PRIVACY.md`). It runs at launch, when the Cost pane opens, and after a row is
booked without a rate, so history made before this version is converted at
the rate of the day it happened, and a rupee-priced row that was waiting
gets its `costUSD` then. Days are UTC.

Each row stores the price in the currency its provider bills: `costUSD` for
dollar-priced models, `listINR` (the Sarvam rate card, v4 column) for
rupee-priced ones, and the other currency is derived at the row's rate. A
row's rupee cost is `listINR ?? costUSD × fxRateINR`, so a Sarvam row shows
its list price exactly, with or without a rate, and every other row at its
day's rate; a Sarvam row booked while Frankfurter was unreachable shows its
rupees at once and its dollars after the back-fill (the USD total carries
`≈` until then).

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
transcription models), matched by the longest model-ID prefix with any
`google/` or `openai/` gateway prefix removed. Gemini 3.8 Flash doubles on 2027-01-01 and the book
switches on that date. Models without an entry are stored with `costUSD = nil`
and shown as unpriced; totals that include an unpriced or estimated call show
a ≈ prefix.

The app cannot tell whether a Gemini key is on the free tier, so it always
shows the paid-tier figure.

Calls served by a gateway (`SettingsStore.activeRoute.gateway` is
`.openRouter` or `.vercel`, for either provider) report their charge in the
response: `usage.cost` on chat and
OpenRouter transcription calls (`TokenUsage.fromOpenAI`), and
`providerMetadata.gateway.cost` on Vercel's transcription protocol
(`TokenUsage.fromVercelTranscription`, which also reads the per-modality token
counts under `providerMetadata.google.usage`). `TokenUsage.reportedCostUSD`
carries it and `UsageRecord` stores it instead of the `PriceBook` figure. Those
rows show the gateway model label (`google/gemini-3.8-flash`,
`openai/gpt-6-luna`); `PriceBook` strips the prefix when a gateway response
carries no cost.

## UI

`CostPane` shows one provider at a time. It opens on the provider selected in
Settings → Advanced, and a Gemini/OpenAI/ElevenLabs/MAI/Sarvam toggle
(`CostSource`) switches to the others; every read filters `usage` rows by
model ID (`CostSource.modelPrefixes`: `gemini` and `google/` for Gemini, `gpt`,
`whisper` and `openai/` for OpenAI, `scribe` and `elevenlabs/` for ElevenLabs,
`saaras` and `sarvam` for Sarvam). A USD/INR toggle (`costPaneCurrency`)
switches every figure; in rupees a total whose rows still lack a rate shows
≈. It shows today, this week, this month, and all time totals; a period
picker drives the by-action and by-model tables and the recent-calls list.
The footer names the price source (`CostSource.pricingNote`): the active
gateway for the selected provider, the provider's pricing page for the other,
ElevenLabs' and Sarvam's list prices on their tabs, and the Frankfurter rate
when rupees are shown. The iPhone's Cost page has the same source and
currency toggles, and both apps refresh the rate and back-fill unrated rows
at launch and when the page opens.
`HistoryPane` shows the summed session cost on each row and the detail sheet
lists each call with its model, what it was billed on, and its cost.

`UsageFormat.measure` writes what a call was billed on: "in 1.2k · out 300"
for token-priced calls, "6m 30s of audio" for audio-priced ones, and "billed
by audio length" for audio-priced calls booked before `audioSeconds` existed.
History, the recent-calls lists on both platforms, and the iPhone's breakdown
rows use it. The Mac's detailed breakdown tables have Tokens in, Tokens out,
and Audio columns, with "—" where a row has none.
