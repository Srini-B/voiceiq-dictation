# 2026-11-06: DeepInfra removed; Claude transcribes only on device

## Why

DeepInfra (Nemotron 3.5 Transcribe) was the cloud speech model for Claude,
which has none of its own. It is no longer needed for any feature, so it is
removed from the Mac and iOS apps. Claude stays as a provider for cleanup,
Agent mode and meeting notes, and every other provider works as before.
Released as 0.6.27 (72).

## What changed

- **Keys.** The DeepInfra key field is gone from Settings on the Mac
  (`ProviderKeySection`) and on iOS (`KeysView`, with the
  `ProviderDeepInfra` favicon). `KeychainStore.Secret.deepInfra` is removed.
- **Transcription.** `GeminiClient` no longer calls DeepInfra, and
  `DeepInfraLiveTranscriber` is deleted. `ModelProvider.transcribes` is false
  for Claude, and `KeychainStore.canTranscribe(with:)` requires it.
- **Claude is text only.** With Claude picked, `SettingsStore.dictationSource`
  and `meetingSource` read On device where local models run, and both
  pickers offer only On device. The stored choice is not overwritten, so
  switching back to Gemini or OpenAI restores it. `meetingTranscribers` is
  empty on Claude, so a meeting no longer falls back to a Gemini or OpenAI
  key. Live transcription is on by default for every provider again; its
  Claude exception existed only for DeepInfra's live path.
- **Alert on picking Claude.** On the Mac and the iPhone, picking Claude
  while the on-device models are not downloaded shows an alert that names
  the missing models and what each blocks: the speech model for any voice
  feature, and Speaker Separation (Mac) for meetings. Its Open Dictation
  Settings button goes straight to them.
- **Meeting code.** The DeepInfra-only paths in `MeetingTranscriber` (timed
  words, track labels, the 240 s window, `timed` and `halves`) and the
  diarizer-only relabel in `LocalMeetingTranscriber` are removed. Every
  provider uses the 600 s window. The cache name keeps `transcribe-v7-*`.
- **Usage.** The Nemotron per-minute price is removed. Old rows keep the cost
  stored when they were booked, and `nvidia/` model IDs still count under
  Claude.
- **Docs.** README, PRIVACY, LOCAL_TRANSCRIPTION, MEETINGS, COST_TRACKING,
  IOS and THIRD_PARTY_NOTICES no longer describe DeepInfra as a feature.

## Also in 0.6.27

The iPhone's History detail now shows **Pipeline**, the time from Stop to the
finished text, which the Mac's detail already showed. The shared
`DictationCoordinator` already saved `pipelineSeconds` on both platforms; only
the iOS view lacked the row. Dictations synced from the Mac carry no pipeline
time, because `HistorySync` does not sync it, so they show no row.

## Decisions

- **Meetings on device too.** A first draft kept Claude meetings in the
  cloud through a Gemini or OpenAI key. The user decided that Claude is for
  text only, so meetings on Claude are transcribed on device like
  dictation. A Claude user who relied on that fallback now needs the
  on-device models, or Gemini or OpenAI as the provider.
- **Stored keys are left alone.** A DeepInfra key already in a user's
  Keychain is not deleted. Nothing reads it, so it is inert.

## Verification

Built and tested on the Mac mini (lobsters-mac-mini): `scripts/test.sh`,
`SIGN_IDENTITY=- scripts/build.sh` and `scripts/build-ios.sh`, compared with
an origin/main baseline for new warnings, then a notarized
`scripts/release.sh` build installed and checked in Settings. Results are in
the PR.

## Rollback

Revert the merge commit on main and release again with a higher build
number. Users who saved a DeepInfra key still have it, so it works again
after the revert without re-entering it.
