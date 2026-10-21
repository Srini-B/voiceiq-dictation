# 2026-10-21: Fluid Speech Mini on iPhone and iPad, live preview on the Mac

## Why

Local transcription was removed from iPhone and iPad on 2026-10-14
(`95d8511`) when Parakeet V3 and Nemotron both failed there. The Mac
switched from Parakeet V3 to Fluid Speech Mini on 2026-10-14 (`f65b905`),
and FluidVoice reports the same model running on iPhone. The request was to
bring that one model back to iOS, to check whether it can drive the live
preview, and to say whether the real-time toggle does anything for a user
who selected Fluid Speech Mini and never downloaded Nemotron.

## What changed

- `LocalSpeechModel.available` lists the models a platform offers: all on
  the Mac, Fluid Speech Mini only on iOS. `SettingsStore.localSpeechModel`
  coerces a stored Nemotron choice to Fluid Speech Mini on iOS, and
  `LocalModelControls` iterates `available`, so the picker, download rows
  and footer show one model there. The `#if os(macOS)` wrappers around the
  model store, installer, manifests and `LocalTranscriber` were removed;
  only `LocalSpeechHelper` (the Mac pipe) stays Mac-only.
- The iOS target links `VoiceIQInference` again and runs
  `trim-inference-resources.py`; `scripts/check-app-bundle.py` now requires
  FluidAudio in the iOS binary. `RemovedLocalModels.swift` is gone.
  `SettingsView` shows the On-device toggle, model controls and the local
  Audio privacy row again, and iOS `AppModel` passes
  `LocalSpeechInference.makeSession` to `LiveTranscriber.makeFromSettings`.
- Fluid Speech Mini preview (`ParakeetPreview`, `ParakeetSession.append`):
  the model is an offline TDT decoder with a 15 s input limit and no
  streaming state, so the preview re-decodes the open tail after each 1 s
  chunk. At 12 s it commits a prefix and cuts the audio at the quietest
  150 ms window in the last 6 s before the 1 s holdback. Token times are
  encoder-frame emissions that ran up to two frames ahead of the audio in
  the logs, so a word emitted up to 200 ms after the cut is committed too
  and `dropOverlap` hides a repeat if the kept audio decodes it again.
  Committing too little would lose words, which nothing could repair.
  `LocalTranscriber.previews` turns the preview on for Fluid Speech Mini
  on the Mac only; Nemotron behaves as before.
- `DictationPane` no longer tells Mac users that live text needs Nemotron.

## Real-time toggle with Fluid Speech Mini selected

Before this change the toggle had no effect on a local Fluid Speech Mini
session: the session ignored `append`, the pill showed no text, and the
saved recording was transcribed after stop. The toggle only chose the cloud
real-time path when no local session started (model missing or failed to
load). With this change it enables the Mac pill preview for Fluid Speech
Mini. On iPhone and iPad it still only governs the cloud fallback: the
preview needs a full re-decode per second and the simulator took 1.4–1.8 s
per 1 s chunk on CPU, so it stays off there until a physical device shows
the Neural Engine keeps up.

## Local meetings (not built)

FluidVoice's Fluid Meet runs Fluid Speech Mini for words and Nemotron 3
Diarization for speakers, all on device. The CoreML offline preset
(`FluidInference/nemotron-3-diarization-coreml`, offline variant) is
199.2 MB (199,162,403 bytes; `weight.bin` 198,654,080). FluidAudio 0.17.7
exposes `Nemotron3Config.offline`, `Nemotron3Models.load(config:directory:computeUnits:)`,
`Nemotron3Diarizer(config:models:)`, `processComplete(audio:speechMask:)`
and `Nemotron3Diarizer.segments(...)` → `[Nemotron3Segment(speakerIndex, startSeconds, endSeconds)]`.
Design for a follow-up: a `LocalMeetingTranscriber` decodes the call audio
with Fluid Speech Mini (token timings on), runs the diarizer over the same
timeline, assigns each word the speaker whose segment overlaps its time,
builds `TimedWord`s, and feeds the existing `SpeakerLinker.overlappingTurns`
→ `TranscriptSegment` → notes path unchanged. The Mac needs a new helper
wire command and a longer helper deadline (60 s idle / 120 s today); iOS
runs it in-process. Needs a diarizer manifest, a `LocalModelStore` row and
a Meetings setting.

## Verification

- `swift test` in `VoiceIQCore`: 143 tests, 0 failures.
- iOS Release build for the iPhone 18 Pro Max simulator (iOS 27.0),
  installed and launched headless (no Simulator GUI on this machine).
  Settings → Dictation shows the On-device toggle, the Fluid Speech Mini
  row (Download 252.7 MB → installed), English tools (103.9 MB), the
  real-time toggle and the footer. Screenshots in `.amp/in/artifacts/`
  (ios-dictation-off, ios-dictation-on, ios-dictation-downloaded, ios-home).
- In-simulator download of the 252.7 MB model succeeded; load 2.4 s. A 7 s
  `say` clip transcribed exactly (confidence 0.98). A 30.7 s clip was fed
  to `ParakeetSession.append` in 1 s chunks through a throwaway hook
  (removed): three commits landed in pauses at "First", "mobile team" and
  "remember"; the preview text had no duplicated or dropped words and the
  final transcript matched the script. Earlier cut rules (token end time,
  nearest onset, 80 ms slack) each duplicated or split a word on the same
  clip ("which me Which means", "the The mobile"), which is why the cut
  reads audio energy and the display de-duplicates.
- macOS: `SKIP_TESTS=1 scripts/release.sh` produced a notarized
  `VoiceiQ-0.6.2.dmg`; the app was installed to `/Applications` and run
  with `localSpeechModel parakeet` and `liveDictationEnabled true`. The
  helper loaded Fluid Speech Mini in 0.15–0.21 s on two hands-free
  dictations, but both recorded digital silence: the Mac mini is driven
  over Jump Desktop, its default input is the 8-channel "Jump Desktop
  Microphone" virtual device, and neither `say` nor `afplay` routed to any
  output device (Jump Desktop Audio, Jump Desktop Microphone, Mac mini
  Speakers) reached that input. The pill preview on the Mac is therefore
  untested end to end; the same `ParakeetSession.append` path was exercised
  with real audio in the simulator.

## Gaps

- No physical iPhone or iPad: decode speed on the Neural Engine, thermal
  behaviour and memory with the 252.7 MB model loaded are unmeasured.
- Preview constants (12 s commit, 1 s holdback, 6 s cut window, 150 ms
  energy window, 200 ms lead) were tuned on one TTS clip in the simulator.
- The Mac pill preview with Fluid Speech Mini needs a run with a real
  microphone.
- The local meeting path is a design only.

## Rollback

Revert the listed files; `LocalSpeechModel.available` and the iOS
`VoiceIQInference` link are the two switches. Settings keys are unchanged;
an iOS install that had `localTranscriptionEnabled` on from before
2026-10-14 starts using Fluid Speech Mini again once the model is
downloaded.
