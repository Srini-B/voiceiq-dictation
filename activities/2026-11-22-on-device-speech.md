# On-device speech returns next to Gemini

2026-11-22. Branch `offline-models`, not released.

## Why

cyron asked to bring back FluidVoice's offline models: Fluid Speech Pro and
Mini for transcription, Fluid 1.1 Ripple and Splash for cleanup, and
FluidMeet-style offline meetings. Online and offline should be chosen apart
for transcription, cleanup and meetings, with Gemini as the default. iPhones
and iPads get Pro (and Splash) with 6 GB of RAM or more, and Mini (and Ripple)
below that. The Mac gets everything.

## What this reverses

- 2026-11-10 (948470a, "Remove every on-device model") made VoiceiQ
  cloud-only and deleted downloaded models at launch. The on-device code from
  before that commit is restored. It was written for this repo, so no
  FluidVoice code is copied (FluidVoice is GPL-3.0; CONTRIBUTING.md's
  clean-room rule applies). Launch now removes only stale renders, not
  `Models`.
- 2026-10-21: iOS ran no speaker diarizer. It now does, because offline
  meetings need speaker labels and the model is 21.6 MB.
- 2026-11-22 (Gemini only) stays for providers: Gemini is still the only
  cloud service.

## Licences and terms

- Fluid Speech Pro and Mini Core ML (Hugging Face, FluidVoice-Labs): CC BY
  4.0. Credited in THIRD_PARTY_NOTICES.md.
- pyannote community-1: CC BY 4.0. FluidAudio: Apache 2.0.
- **Fluid 1.1 Ripple and Splash: not used.** They are served from
  `models.fluidvoice.com` under ALTIC-MODEL-TERMS.md, which allows use only
  through official FluidVoice applications and forbids copying, extracting or
  integrating them into a third-party application, with no personal-use
  exception. Fluid-1 on Hugging Face is likewise non-commercial and forbids
  integration. Their open bases (LFM2.5-1.2B, LFM Open License; Qwen3.5-2B,
  Apache 2.0) are the alternative, pending cyron's decision.
- FluidMeet is a FluidVoice app feature, not a separate model. Offline
  meetings here use FluidAudio with pyannote, which is the same approach.

## Decisions

- Cleanup choices are Gemini or Off. Gemini cleanup of an on-device
  transcript sends text only and keeps the built-in writing rules, custom
  rules, dictionary and regional spelling.
- The iOS RAM line is `physicalMemory >= 5 GiB`, because iOS reports a 6 GB
  device as about 5.5 GiB.
- Pro now points at FluidVoice's official 8-bit Core ML repo (652.3 MB)
  instead of this repo's own conversion. The conversion scripts are removed.
- On iOS the source pickers are menu rows, because a segmented picker there
  shows no label.
- With on-device dictation and the model downloaded, VoiceiQ does not ask for
  an API key (`DictationRoute.isAvailable`).

## Verification

On a cloud Mac (macOS 27.2, Xcode 27.2):

- `swift test` in VoiceIQCore: 157 tests, 0 failures.
- Mac and iOS Simulator Debug builds succeed.
- In the iOS Simulator (iPhone 17 Pro) with Dictation On device and Writing
  rules Off, a keyboard-started dictation ran on Fluid Speech Pro: load 2.3 s,
  decode 1.55 s for 9.7 s of audio, `modelID` `fluid-speech-pro-local`,
  status inserted. The English tools downloaded in the app.
- Numbers against Gemini are in [docs/ON_DEVICE.md](../docs/ON_DEVICE.md).

Not verified: the signed and notarized Mac release (no Developer ID on the
cloud Mac), the Mac app end to end through the helper, and a real iPhone
(cold Core ML load, RAM line, background warm-up).
