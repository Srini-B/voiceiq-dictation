# 2026-10-21: ElevenLabs Scribe v2 returns as a third transcription source

Local, uncommitted at the time of writing.

## Why

The owner asked for ElevenLabs back, for dictation and for meetings, as a
source a user picks next to the provider and the on-device models. The
2026-10-05 removal ([Gemini and OpenAI only](2026-10-05-gemini-and-openai-only.md))
took it out with Sarvam and the gateways; the old client and settings were
restored from that commit's parent (`bf435d6^`) and reshaped around the
on-device settings that landed since.

## Decisions

- One `TranscriptionSource` per feature (`dictationSource`, `meetingSource`)
  instead of the old single `transcriptionSource` plus two on-device booleans.
  Each feature has a segmented picker: On device, ElevenLabs, provider. The
  old booleans are still read when a new key is absent, so nobody loses an
  on-device choice; the booleans are now derived properties.
- The ElevenLabs segment is shown only while its key is stored, or while it is
  already the selection, so a removed key never leaves an empty picker.
  Routing also checks the key: with the key gone, dictation and meetings use
  the provider (`cloudDictationSource`, `meetingSpeechRoutes`).
- No ElevenLabs → provider fallback inside a meeting, as before 2026-10-05.
  A user who picks ElevenLabs gets ElevenLabs or a retryable failure.
- `ModelEndpoint` is separate from `ModelProvider`. ElevenLabs is a
  speech-to-text host and never a writing provider, so the provider picker,
  `meetingOrder`, `ModelProvider.other` and the key cards are untouched.
- Real-time dictation stays batch-only on ElevenLabs: Scribe has no streaming
  endpoint we use, and streaming to the provider's socket would send audio to
  a host the user did not pick. The toggle remains for the provider source.
- Translate and Ask Anything go through Scribe too: they share the dictation
  transcript path and the user chose where audio goes.
- iOS shows the two pickers in separate sections with
  `SettingsSectionHeader("Transcription")` and `"Notes transcription"`.
  An iOS Form hides a segmented picker's label, so two pickers in one section
  were indistinguishable. The Mac pane keeps both rows in one section because
  the labels render there.
- The Mac key section is its own file (`ElevenLabsKeySection`), copied from
  `OpenAIKeySection`, matching how the Advanced pane is built.
- `CostSource.elevenLabs` is a third Cost tab. Rows are booked locally from
  `audio_duration_secs` at list price, as before.

## Verification

- `swift build` and `swift test` in `VoiceIQCore`: 143 passed, 0 failed.
- Mac notarized release (`scripts/release.sh`, `VoiceiQ-0.6.2.dmg`) installed
  and launched: Settings → Dictation shows the Transcription picker (On
  device | Gemini) above the model rows, Real-time transcription, Meeting
  transcription picker and the diarizer row; Settings → Advanced shows the
  ElevenLabs API key section between the provider key and TinyFish.
  Screenshots `.amp/in/artifacts/mac-dictation-full.png`,
  `mac-advanced-elevenlabs.png`.
- iOS Release simulator build installed on iPhone 18 Pro Max and iPad Air
  11-inch (M4): TRANSCRIPTION and NOTES TRANSCRIPTION sections with their
  pickers, the ElevenLabs card under Optional in Provider & Keys, the Privacy
  rows naming the chosen source. A fresh iPad install defaults both pickers to
  the provider. Screenshots `iphone-dictation.png`, `iphone-keys.png`,
  `iphone-privacy.png`, `ipad-dictation.png`.

## Gaps

- No ElevenLabs key was available, so no request reached `api.elevenlabs.io`
  and the ElevenLabs segment appearing after a key is saved was not seen on
  screen. The client is the 2026-10-05 code with `scribe_v2`, against the API
  reference read 2026-09-28.
- Shared `MeetingEngine` failure strings still say "Meeting" and "Settings →
  Advanced" on iPhone and iPad, where the tab is now Notes and keys live in
  Provider & Keys.
