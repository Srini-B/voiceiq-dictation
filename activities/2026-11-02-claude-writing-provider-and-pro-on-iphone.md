# 2026-11-02: Claude as a writing provider; Fluid Speech Pro on iPhone

## Why

The owner asked for two changes:

- Claude must be a standard writing provider. Before, it existed only as
  "Claude + Nemotron", which needed both an Anthropic and a DeepInfra key.
  Gemini and OpenAI stay full cloud options. Claude does everything except
  transcription, so it is used with an on-device model.
- Fluid Speech Pro must be available on iPhone, loaded the same way as
  Mini.

## Decisions

- The provider is now "Claude" and needs only the Anthropic key
  (`KeychainStore.hasKey`). The DeepInfra key stays as an optional extra:
  with it, Claude can still transcribe in the cloud with Nemotron 3.5
  Transcribe. This keeps the earlier behavior for anyone who has both keys.
  To drop DeepInfra completely, remove the key sections and
  `GeminiClient+Anthropic`'s DeepInfra calls.
- DeepInfra stays a choice for every Claude transcription: dictation, Ask,
  Translate, Agent and meetings. The pickers always show On device and
  Nemotron 3.5. A first version hid Nemotron 3.5 without the DeepInfra key;
  the owner wanted the choice visible, so now picking it without the key
  shows "Add a DeepInfra key in Settings → Advanced to use Nemotron 3.5."
  (Provider & Keys on iOS) under the picker.
- `GeminiClient.deepInfraTranscription` throws `.auth` with no DeepInfra
  key before any upload, so audio never reaches a host the user did not
  set up. The pill says "Claude needs On device or a DeepInfra key".
- Cloud fallbacks follow the same rule: `LiveTranscriber` passes
  `KeychainStore.canTranscribeInCloud` as `cloudOnColdLoad`, and meetings use
  `SettingsStore.meetingTranscribers` for cloud transcripts. Notes still use
  `meetingProviders`.
- Mac onboarding still offers only Gemini and OpenAI. A new Claude user
  cannot dictate until an on-device model is downloaded, which onboarding
  does not do.
- Fluid Speech Pro's Core ML build targets macOS 15 and iOS 18. The app
  supports macOS 14 and iOS 17. `LocalSpeechModel.available` now offers Pro
  only on macOS 15+ and iOS 18+. This also closes a gap in the Mac release
  of Pro, which listed it on macOS 14.
- iOS needed no new load path. Pro already goes through
  `LocalSpeechInference.makeSession` (`ParakeetSession`, CPU encoder) like
  Mini. `ModelWarmer` now records the iOS version and the selected model, so
  selecting Pro warms it the next time the app opens.

## Verification

- `scripts/test.sh`: 143 tests pass. `scripts/build-ios.sh` builds.
- iOS Simulator (iPhone 17e, iOS 27) with both keys saved: Provider & Keys
  shows Gemini / OpenAI / Claude, the Anthropic card under Provider and
  DeepInfra under Optional. The Pro row offers "Download (1.23 GB)". The
  in-app download finished. After Pro was selected and the app was
  reopened, the warm-up loaded Pro in-process: "Parakeet cold load
  complete in 4.54s, vocabulary=false, encoder=cpu", then released it.
- Clean iOS Simulator (iPhone Air) with no keys, Claude selected and
  `dictationSource=provider`: the Transcription picker shows On device /
  Nemotron 3.5 with Nemotron 3.5 selected and the DeepInfra hint under it.
  Picking On device removes the hint.
- Notarized Mac release 0.6.21 installed on the Mac mini: the Advanced pane
  shows Claude, the Anthropic key, and the DeepInfra key with
  "Optional. Lets Claude transcribe in the cloud with Nemotron 3.5
  Transcribe." The Dictation pane shows On device / Nemotron 3.5 because a
  DeepInfra key is saved. A hands-free dictation was transcribed by
  `fluid-speech-mini-local` and cleaned by `claude-sonnet-5-5`.
- Not verified: the Mac UI without a DeepInfra key (the Mac mini's key was
  not removed), and Pro on a physical iPhone. The Simulator does not apply
  iPhone memory limits, and Pro's 16-bit encoder is 1.19 GB.

## Follow-up: meetings use the selected model

The owner saw "Notes use cloud transcription until Fluid Speech Mini is
downloaded" on an iPhone with Fluid Speech Pro downloaded and selected.
On-device meetings were hard-wired to Mini. They now use the model checked
in the list (`LocalMeetingTranscriber` holds `SettingsStore.localSpeechModel`),
the rows stay selectable while only meetings are on device, and
`LocalMeetingJob` no longer passes `.english` to FluidAudio, which would
block Cyrillic and Greek tokens with Pro's top-K joint. The warm-up loads
the selected model for meetings too.

## Follow-up: keyboard waveform empty on iPhone

On 0.6.22 the owner's iPhone showed the recording panel (timer, Listening,
buttons) with no waveform at all, not even the flat baseline bars. The same
code drew the bars in the iPhone 17e Simulator in light and dark mode, in the
in-app field and in Safari after the app-switch bounce, and with
`TimelineView` paused (the Reduce Motion path). No physical iPhone was
connected, so the cause on device is not confirmed. `LiveWaveform` was the
only keyboard view using `Canvas` and `TimelineView`; it now draws plain
`Capsule` views advanced by a timer, the same update style as the rest of the
keyboard. Checked in the Simulator: bars follow the simulated mic while
listening and pulse blue while writing. Needs a check on a device.
