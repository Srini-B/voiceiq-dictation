# 2026-10-28: ElevenLabs removed from the app again

## Why

The owner asked to remove the ElevenLabs options from the app completely.
ElevenLabs Scribe v2 had returned on 2026-10-21
([ElevenLabs returns](2026-10-21-elevenlabs-returns.md)) as a third
transcription source next to the on-device models and the provider.

## Decisions

- The per-feature source pickers stay, with two segments: On device and the
  provider. Reverting the whole 2026-10-21 commit would have brought back the
  older on-device toggles, which is a UI change nobody asked for.
- A stored ElevenLabs choice reads as the provider, not as the older
  on-device boolean, so nobody silently moves to a local model.
- The code that existed only to fit ElevenLabs beside the providers is gone
  too: `ModelEndpoint`, `MeetingTranscriber.SpeechRoute`,
  `SettingsStore.meetingSpeechRoutes` and `cloudDictationSource`. These files
  went back to their pre-2026-10-21 shape by reverse-applying that commit's
  hunks where only ElevenLabs had changed them.
- A saved ElevenLabs key stays in the Keychain, unread, as with the services
  removed on 2026-10-05. Old `scribe_v2` usage rows stay in the database but
  no Cost Analysis tab shows them.

## Verification

- `scripts/test.sh`: 143 tests pass.
- The iOS app (`VoiceIQiOS`) builds for the simulator.
- A signed and notarized Mac release was installed and the Settings panes were
  checked for ElevenLabs.
