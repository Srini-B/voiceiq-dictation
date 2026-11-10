# 2026-11-10: Cloud only, Gemini and OpenAI

## Why

The owner is finishing VoiceiQ as a cloud-only app. Two providers remain:
Google (Gemini) and OpenAI. The owner dropped every on-device model and
dropped Claude as a provider.

## What changed

- **Claude.** It is no longer a provider. A stored Claude choice reads as
  Gemini. A stored Anthropic key stays in the Keychain, unused. Past Claude
  spend still shows on the Cost page: the Claude segment appears only while
  the ledger has Claude rows, and `PriceBook` keeps its prices. Agent mode's
  custom provider can still use the Anthropic Messages format.
- **On-device models.** Gone: Fluid Speech Mini and Pro (Parakeet), the
  English tools pack (Silero VAD and Parakeet CTC), the pyannote speaker
  diarizer, the iPhone's background warm-up task, the `VoiceIQInference`
  target and the FluidAudio package. Settings lose the transcription and
  meeting source pickers, the model rows, the language menu and their
  footers. Meetings are always transcribed by the provider.
- **Real-time transcription.** With it on, dictation streams to Gemini Live
  or OpenAI Realtime. The keyboard's recording strip shows those words.
- **The helper.** `VoiceiQLocalSpeech` now runs only the Chrome extension's
  native messaging host, which moved into `VoiceIQSpeech`. It keeps its name
  and bundle id, because installed host manifests point at it.
- **Disk cleanup.** At every launch the app deletes
  `Application Support/VoiceiQ/Models` (all downloaded models, including the
  TestFlight writer), and on the Mac
  `~/Library/Caches/io.blue.voiceiq.localspeech`, the helper's Core ML cache.
  It runs off the main thread and ignores errors
  (`FileLayout.removeRetiredModels`). The Mac app is not sandboxed, so both
  paths are the real ones. Remove the cleanup once every install has launched
  a build from 2026-11-10 or later.
- **Keyboard start.** A refused keyboard start now stays in VoiceiQ and shows
  the reason, instead of returning to the host app.

## What users lose

- Offline dictation. Without a network, dictations queue and send later.
- The on-device languages: Fluid Speech Pro's 25 European languages on
  device. The providers' own languages remain.
- Keyless use. A Gemini or OpenAI key is required again.
- On-device meeting transcription and speaker separation.

## Not checked here

This was done in an orb with no Swift toolchain. The Apple builds and tests
run on a Mac.
