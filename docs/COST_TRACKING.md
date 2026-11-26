# Cost tracking

VoiceiQ meters every Gemini model call and shows the result under
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
length. No model VoiceiQ calls now is priced that way; the column holds the
length for rows that older builds booked from OpenAI's transcription models
and ElevenLabs Scribe. It was added in migration `v2-audioSeconds`;
per-minute calls booked before it have no length.

Activities: `dictation`, `meeting`, `other`. Stages: `transcribe` (one per
dictation, or per chunk of a dictation over ten minutes), `meetingTranscribe`,
`meetingSummary`, `meetingChat`. The activities `askAnything`, `translate`
and `agent` and the stages `liveTranscribe`, `cleanup`, `answer`,
`translate`, `webQuery` and `agentStep` are no longer booked; they stay so
rows from older builds still read.

The ledger is separate from `history.sqlite` so deleting a dictation or its
audio never changes what it cost.

## Where the counts come from

`GeminiClient.post` is the only REST transport, so it is the one place that
reads usage on a 200. Two envelopes are handled by `TokenUsage`:

- `:generateContent` → `usageMetadata` (`promptTokensDetails`,
  `candidatesTokensDetails`, `thoughtsTokenCount`, `cachedContentTokenCount`).
  Meeting notes and meeting chat use it. Dictation uses
  `:streamGenerateContent?alt=sse`; `GeminiClient.joinedEventStream` joins
  the events into the same envelope with the last event's usage, so it is
  metered the same way.
- A dictation request that is cancelled is not recorded: the slower of two
  raced attempts (`DictationHedge`), or a send-on-pause request the speaker
  talked over. Gemini bills nothing for a stream cancelled before its first
  chunk. A request that finished streaming before it was cancelled is
  metered as usual. One cancelled mid-stream may be billed but is not in the
  ledger; the `send-on-pause: ... billed: true` log lines count those.
- `v1beta/interactions` → `usage`. `total_output_tokens` came back 0 while
  `model_invocation_token_counts` carried the real output count (probed
  2026-09-26), so the per-invocation list is authoritative. Meeting
  transcription uses it.

## Retired providers

OpenAI and ElevenLabs were providers until 0.7.12, and Claude until
2026-11-10. Their rows keep their stored cost, and `PriceBook` keeps their
prices so rows without one still price: OpenAI's token prices and per-minute
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

`PriceBook` holds paid-tier Standard prices per million tokens from
ai.google.dev/gemini-api/docs/pricing (copied 2026-09-26), matched by the
longest model-ID prefix. A `google/` or `openai/` prefix, found on rows booked
through the gateways older builds supported, is removed first. Gemini 3.8
Flash doubles on 2027-01-01 and the book switches on that date. Models
without an entry are stored with `costUSD = nil` and shown as unpriced;
totals that include an unpriced or estimated call show a ≈ prefix.

The app cannot tell whether a Gemini key is on the free tier, so it always
shows the paid-tier figure.

## UI

`CostPane` shows Gemini. Every read filters `usage` rows by model ID
(`CostSource.modelPrefixes`: `gemini` and `google/` for Gemini). OpenAI
(`gpt`, `whisper`, `openai/`), ElevenLabs (`scribe`) and Claude get a segment
in a source toggle only while the ledger still has calls booked to them
(`CostSource.isCurrent` is false for them; each reload counts their rows).
With Gemini alone there is no toggle. Rows from services older builds
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
