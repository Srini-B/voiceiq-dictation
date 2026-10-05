# Gemini and OpenAI only

2026-10-05. Local, uncommitted at the time of writing.

## Why

The owner tested Sarvam's writing model and found it poor. Sarvam's other
chat models (GLM-5.3, DeepSeek V4 Flash, Gemma 4) are behind a beta
allow-list: the key lists them on `GET /v2/models`, but every
`/v2/chat/completions` and `/v2/responses` call answers 400 "This endpoint is
currently in beta and not available". With `reasoning_effort` on, `sarvam-105b`
wrote better text but took 22 to 45 s and up to 8,192 tokens per dictation.
With it off (the shipped setting), it translated a Hinglish dictation into
English and once continued the prompt's examples. The owner then asked to
remove Sarvam, ElevenLabs and OpenRouter, and to keep only Gemini and OpenAI.

## What was removed

- Sarvam: Saaras V4 speech-to-text (sync and batch), Sarvam 105B writing,
  the Spoken language setting, rupee costs, and the Frankfurter rate fetch.
- ElevenLabs Scribe v2 for dictation and meetings.
- OpenRouter and Vercel AI Gateway, with the gateway picker and the gateway
  meeting path (flash model with reference clips as separate parts).
- MAI Transcribe 2 and its Transcript style setting, which only ran through
  those gateways.
- `ModelGateway`, `ModelRoute`, `ModelEndpoint`, `TranscriptionSource`,
  `WritingSource`, `MAITranscribeStyle`, `SarvamLanguage`, `FXRates`, and
  `MeetingTranscriber.SpeechRoute`. Calls now switch on `ModelProvider`.

## Decisions

- Kept: TinyFish (Ask Anything search, not a model provider) and the Agent
  mode custom endpoint (`AgentProviderOverride`), which is a user-entered host,
  not a bundled integration.
- `usage.sqlite` keeps migrations `v3-fx` and `v4-listINR`. The columns stay
  unused, so existing databases keep a known migration history. Old rows from
  removed services stay in the ledger and match neither Cost tab.
- Keys already saved for the removed services stay in the Keychain. The app
  no longer reads them. They were not deleted, because deleting user secrets
  was not requested.
- A stored `modelProvider` of `openRouter` or `vercel` (older builds) reads as
  Gemini. A stored transcription or writing source is ignored.
- Meetings run on the selected provider, then on the other when only its key
  is saved (`SettingsStore.meetingProviders`). The meeting window cache is now
  named by provider (`transcribe-v6-gemini-600`), so a retry of a meeting
  started on an older build transcribes again once.
- OpenAI's 429 `insufficient_quota` now maps to `network("insufficient_credits")`
  (was `gateway_insufficient_credits`). It stays retryable.

## Verification

- `scripts/test.sh`: 143 tests passed.
- macOS (`VoiceIQ`) and iOS (`VoiceIQiOS`) Debug builds succeeded.
- `scripts/release.sh` built, signed and notarized 0.5.14 (Accepted, stapled).
  The installed app's Advanced pane shows only Provider, the selected
  provider's key and models, TinyFish and the Agent mode endpoint. Cost shows
  Gemini and OpenAI in USD only. Privacy names only Google plus TinyFish.
- Retry Transcription on a 20 s History recording in the installed app: on
  Gemini, one `gemini-3.8-flash` call ($0.0060); on OpenAI,
  `gpt-transcribe`, `whisper-1` as SECOND, then `gpt-6-luna` ($0.0044). All
  calls answered 200. The provider was set back to Gemini afterwards.
- `rg` for the removed service names finds only compatibility comments in
  `SettingsStore`, `ModelProvider`, `PriceBook` and `UsageStore`, the money
  rule in `PromptV1` (rupees as spoken currency), and dated design records.

## Follow-up the same day

- Removed "Use the previous transcription endpoint" on both apps, with
  `SettingsStore.usesLegacyTranscribeEndpoint` and the `:generateContent`
  transcription call (`GeminiClient.transcribe`) it switched to. Gemini
  transcription always uses the interactions endpoint. A stored
  `legacyTranscribeEndpoint` value is ignored.
- The Dictation pane no longer has an "Experimental" heading: Better hearing
  in loud rooms, Agent mode and its shortcut row are an ordinary section. The
  iPhone's Dictation page drops the heading over Better hearing in loud rooms
  too. The Agent mode "no model" message now points to Settings → Advanced.
