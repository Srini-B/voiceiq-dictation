# Cost tracking

VoiceiQ meters every AssemblyAI call and shows the result under
Settings → Cost Analysis (`voiceiq://settings/cost`) and per dictation in
History. Costs are in US dollars.

## What is recorded

Each successful model call becomes one `UsageRecord` in
`~/Library/Application Support/VoiceiQ/usage.sqlite` (GRDB, WAL). Fields:
time, activity, stage, model, session ID, token counts by modality (text,
audio, image, cached in; text, audio, thought out), an `isEstimated` flag,
`costUSD`, and `audioSeconds`. Each call also writes a `usage` line to the
log with its tokens in (audio, image and cached shown separately) and out, so
the implicit-cache hit share of real dictations can be read with
`log show --predicate 'eventMessage BEGINSWITH "usage dictation"'`. The table also has `fxRateINR`, `fxDate`
(migration `v3-fx`) and `listINR` (migration `v4-listINR`) from the removed
Sarvam integration. The migrations stay registered so existing databases keep
a known history, but nothing reads or writes those columns.

`audioSeconds` is the audio a call was billed for, on models priced by audio
length: AssemblyAI's speech models (and, in rows older builds booked,
OpenAI's transcription models and ElevenLabs Scribe). It was added in
migration `v2-audioSeconds`; per-minute calls booked before it have no length.

Activities: `dictation`, `meeting`, `other`. Stages: `liveTranscribe` (the
STT-3.7 Realtime stream of a dictation), `transcribe` (pre-recorded
transcription, when the stream failed or for a Universal-2 language),
`cleanup` (the writing model), `meetingTranscribe`, `meetingSummary`,
`meetingChat`. The activities `askAnything`, `translate` and `agent` and the
stages `answer`, `translate`, `webQuery` and `agentStep` are no longer
booked; they stay so rows from older builds still read.

The ledger is separate from `history.sqlite` so deleting a dictation or its
audio never changes what it cost.

## Where the counts come from

Every call goes through `AssemblyAIClient` (and `RealtimeTranscription` for
the stream), and model IDs are booked as `assemblyai/<model>`.

- **Speech** is billed per hour of audio, so the call is booked with its cost
  (`TokenUsage.reportedCostUSD`) and `audioSeconds`. Pre-recorded STT-3.7
  ($0.21 an hour) or Universal-2 ($0.15) is booked from the transcript's
  `audio_duration`, at the rate of the model that ran (`speech_model_used`),
  plus speaker labels ($0.02) when the request used them. The
  Realtime stream ($0.30 an hour) is billed for the time the session is
  open, so it is booked from that time when the session closes.
- **The LLM Gateway** answers in OpenAI's chat-completion shape for every
  model; `TokenUsage.fromChatCompletion` reads `usage` (`prompt_tokens` with
  `prompt_tokens_details.cached_tokens`, `completion_tokens` with
  `completion_tokens_details.reasoning_tokens`) and `PriceBook` prices it.
  The dictation writer, meeting notes and meeting chat use it.

`AssemblyAIPrices` in `AssemblyAIClient.swift` holds the speech list prices
from assemblyai.com/pricing. At those prices a 20-second dictation costs
about ₹0.24 with GPT-6 Luna writing it, and a meeting about ₹28 per hour of
speech. AssemblyAI's free credit is not subtracted.

## Retired providers

Gemini was the provider until 0.7.19, OpenAI and ElevenLabs until 0.7.12,
and Claude until 2026-11-10. Their rows keep their stored cost, and `PriceBook` keeps their
prices so rows without one still price: Gemini's token prices, OpenAI's token prices and per-minute
transcription prices (`gpt-transcribe`, `gpt-live-transcribe`,
`gpt-4o-transcribe`, `whisper-1`), ElevenLabs' per-hour Scribe prices
(`scribe_v3`, `scribe_v3_live`, `scribe_v2`, `scribe_v2_realtime`), and
Claude's token prices with the cache-write surcharge. Claude rows count under
the Claude source (`claude`, `anthropic/` and `nvidia/` model IDs; `nvidia/`
rows were booked before 2026-11-06, when Claude transcribed with Nemotron 3.5
Transcribe on DeepInfra).

## Attribution

`UsageMeter.scope` is a task-local `UsageScope(activity, sessionID)`. It is set
around the dictation finalize task in `DictationCoordinator`, the retry queue's
transcribe, and `MeetingEngine` processing and meeting chat.
Calls without a scope are booked as `other`.

## Pricing

`PriceBook` holds prices per million tokens, matched by the longest model-ID
prefix. The LLM Gateway charges the model providers' list prices (GPT-6 Luna:
$0.10 in, $0.01 cached, $0.50 out, read 2026-11-28). An `assemblyai/`,
`google/` or `openai/` prefix is removed first. Speech rows carry their cost
and need no entry. Models without an entry are stored with `costUSD = nil`
and shown as unpriced; totals that include an unpriced or estimated call
show a ≈ prefix.

## UI

`CostPane` shows AssemblyAI. Every read filters `usage` rows by model ID
(`CostSource.modelPrefixes`: `assemblyai/` for AssemblyAI). Gemini
(`gemini`, `google/`), OpenAI
(`gpt`, `whisper`, `openai/`), ElevenLabs (`scribe`) and Claude get a segment
in a source toggle only while the ledger still has calls booked to them
(`CostSource.isCurrent` is false for them; each reload counts their rows).
With AssemblyAI alone there is no toggle. Rows from services older builds
supported (MAI Transcribe 2, Sarvam) match no source. It shows
today, this week, this month, and all time totals; a period picker drives the by-action
and by-model tables and the recent-calls list. The footer names the price
source (`CostSource.pricingNote`): the provider's pricing page. The iPhone's
Cost page works the same way.
`HistoryPane` shows the summed session cost on each row and the detail column
(`DictationDetail`) lists each call with its model, what it was billed on, and its cost.
Builds before 2026-11-10 could transcribe on device. Those rows have model
IDs such as `fluid-speech-mini-local`, `fluid-speech-pro-local`,
`parakeet-v3-local` and `nemotron-3.5-multilingual-local`, stage `transcribe`,
and an explicit zero cost. They still appear in session details but match no
source.

`UsageFormat.measure` writes what a call was billed on: "in 1.2k · out 300"
for token-priced calls, "6m 30s of audio" for audio-priced ones, and "billed
by audio length" for audio-priced calls booked before `audioSeconds` existed.
History, the recent-calls lists on both platforms, and the iPhone's breakdown
rows use it. The Mac's detailed breakdown tables have Tokens in, Tokens out,
and Audio columns, with "—" where a row has none.
