# Cost tracking

VoiceiQ meters every Gemini, OpenAI and ElevenLabs model call and shows the result under
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
they arrive and books usage once at finish or cancellation. A single Gemini
turn uses its largest reported total. Multi-turn sessions and sessions without
usage reports estimate from all accepted audio, rather than treating one
turn's usage as the session total. The estimate uses audio seconds × 25
tokens/s and output characters ÷ 4, flagged `isEstimated`.
OpenAI live transcription estimates cost from accepted audio duration at
$0.017/minute. Live and batch fallback attempts appear as separate stages
under the same dictation. A failed live attempt can therefore add cost even
when the final transcript comes from a batch upload.

On OpenAI's own API, the transcription models (`gpt-transcribe`,
`gpt-4o-transcribe`, and `whisper-1`, which older builds also called
for a second transcript) bill per audio minute and report
`usage: {type: "duration", seconds}`; `TokenUsage.fromOpenAIDuration` books
`seconds / 60 × PriceBook.perMinutePrice` as `reportedCostUSD` with no token
counts. Chat models (GPT-6.1 Terra, GPT-6 Astra, GPT-6 Luna, and
`gpt-4o-transcribe-diarize`, which bills tokens) use the OpenAI-shaped
`usage` block (`TokenUsage.fromOpenAI`).

Claude was a provider until 2026-11-10. Its rows keep their stored cost and
count under the Claude source (`claude`, `anthropic/` and `nvidia/` model IDs;
`nvidia/` rows were booked before 2026-11-06, when Claude transcribed with
Nemotron 3.5 Transcribe on DeepInfra). `PriceBook` keeps the Claude prices, so
those rows still price. Agent mode's custom provider can still call Claude
models in the Anthropic Messages format; those calls use
`TokenUsage.fromAnthropic`.

A cache write counts as input tokens. `fromAnthropic` also keeps the write's
TTL from `usage.cache_creation`, and `ModelPrice.cost` adds the write surcharge:
0.25× input for a five-minute write (billed 1.25×) and 1× for a one-hour write
(billed 2×). Rows booked before 0.6.13 have no surcharge.

## Attribution

`UsageMeter.scope` is a task-local `UsageScope(activity, sessionID)`. It is set
around the dictation finalize task in `DictationCoordinator`, the retry queue's
transcribe, and `MeetingEngine` processing.
Calls without a scope are booked as `other`.

## Pricing

`PriceBook` holds paid-tier Standard prices per million tokens from
ai.google.dev/gemini-api/docs/pricing (copied 2026-09-26) and Standard prices
from developers.openai.com/api/docs/pricing (copied 2026-09-28, GPT-6 Astra
2026-10-21, GPT-6.1 Terra 2026-10-27; GPT-6 Luna,
GPT-6 Sol, `gpt-4o-transcribe-diarize`, plus the per-minute table for the
transcription models), matched by the longest model-ID prefix. A `google/` or
`openai/` prefix, found on rows booked through the gateways older builds
supported, is removed first. Gemini 3.8 Flash doubles on 2027-01-01 and the book
switches on that date. Models without an entry are stored with `costUSD = nil`
and shown as unpriced; totals that include an unpriced or estimated call show
a ≈ prefix.

The app cannot tell whether a Gemini key is on the free tier, so it always
shows the paid-tier figure.

ElevenLabs Scribe returns no usage block, so `ElevenLabs.usage`
(`GeminiClient+ElevenLabs.swift`) prices each call from its audio length
(`audio_duration_secs`, else the length sent) at the list prices on
elevenlabs.io/pricing/api, copied 2026-11-12 and the same on every plan:

| Scribe v3 (`scribe_v3`, dictation and meetings) | Price |
|---|---|
| Base | $0.20 / hour |
| Dictionary terms (`keyterms`) | +$0.05 / hour |
| Formatting instruction (`transcript_edit`) | +$0.07 / hour, at least 10 s per request |
| Hiding card and ID numbers (`entity_detection`, meetings, opt-in) | +$0.06 / hour (30%, from the help center; not in the table) |

| Scribe v3 Live (`scribe_v3_live`, the live meeting transcript) | Price |
|---|---|
| Base | $0.22 / hour |
| Dictionary terms and keyterm library | +$0.08 / hour, billed once for both |

A meeting recorded with ElevenLabs is billed twice: Live for the whole
recording while it runs (booked as "Live transcription" when it stops), and
batch for its speech afterwards. With dictionary terms that is about $0.30
plus up to $0.25 per hour of meeting.

The guides give the add-ons as +20% and +30% instead; the table is used
because it is what the bill shows. Silence is billed, which is why meetings
send only their stretches of speech. `scribe_v2` and `scribe_v2_realtime`
keep their prices for rows booked in 2026-09 and 2026-10. Hours included in
an ElevenLabs plan are not subtracted.

## UI

`CostPane` shows one source at a time. It opens on the provider selected in
Settings → Advanced, and a Gemini/OpenAI toggle (`CostSource`)
switches between them; every read filters `usage` rows by model ID
(`CostSource.modelPrefixes`: `gemini` and `google/` for Gemini, `gpt`,
`whisper` and `openai/` for OpenAI). An ElevenLabs segment (`scribe` model IDs,
including the `scribe_v2` rows of 2026-09 and 2026-10) joins while an
ElevenLabs key is stored or the ledger has its rows. A Claude segment joins the toggle only
while the ledger has Claude rows (`CostSource.isCurrent` is false for it; each
reload counts its rows). Rows from services older builds supported
(MAI Transcribe 2, Sarvam) match no tab. It shows
today, this week, this month, and all time totals; a period picker drives the by-action
and by-model tables and the recent-calls list. The footer names the price
source (`CostSource.pricingNote`): the provider's pricing page. The iPhone's
Cost page has the same source toggle.
`HistoryPane` shows the summed session cost on each row and the detail column
(`DictationDetail`) lists each call with its model, what it was billed on, and its cost.
Builds before 2026-11-10 could transcribe on device. Those rows have model
IDs such as `fluid-speech-mini-local`, `fluid-speech-pro-local`,
`parakeet-v3-local` and `nemotron-3.5-multilingual-local`, stage `transcribe`,
and an explicit zero cost. They still appear in session details but match no
provider tab.

`UsageFormat.measure` writes what a call was billed on: "in 1.2k · out 300"
for token-priced calls, "6m 30s of audio" for audio-priced ones, and "billed
by audio length" for audio-priced calls booked before `audioSeconds` existed.
History, the recent-calls lists on both platforms, and the iPhone's breakdown
rows use it. The Mac's detailed breakdown tables have Tokens in, Tokens out,
and Audio columns, with "—" where a row has none.
