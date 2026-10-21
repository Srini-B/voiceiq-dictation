# 2026-10-21: iPhone and iPad keep only Fluid Speech Mini, meetings included

## Why

The owner limited on-device work on iPhone and iPad to Fluid Speech Mini,
run after the recording ends. No real-time path, no Nemotron, no Nemotron 3
Diarization there; those stay on the Mac. On-device dictation already met
this (`LocalSpeechModel.available`, `LocalTranscriber.previews`). On-device
meetings did not: they required the 199 MB diarizer on both platforms.

## Decisions

- `LocalMeetingTranscriber.diarizes` is a compile-time platform flag. iOS
  acquires a session on Fluid Speech Mini only, `isReady` ignores the
  diarizer store, and `LocalMeetingRequest.diarizerDirectory` is sent as nil.
  `LocalMeetingJob.run` skips the diarizer pass and returns no segments, so
  `label` gives every word `s1` and the transcript reads as Speaker 1.
  iOS records the mic alone, so a single speaker loses less than it seems;
  cross-talk is not separated, which the cloud path did do.
- The diarizer row and its footer sentence are hidden on iOS through the same
  flag, so the Mac settings are unchanged.
- The iOS "Real-time transcription" toggle stays. It is the cloud live path
  (Gemini or OpenAI websocket, default on) and removing it would slow cloud
  dictation. It moved back to its own section, as before the on-device
  section grew, so it no longer reads as part of the on-device feature.
  Remove it only if the owner confirms.
- Mac helper protocol: the request JSON omits `diarizerDirectory` when nil.
  The Mac app always sends a URL, and app and helper ship together, so no
  mixed-version decoding happens.

## Verification

- `swift build` and `swift test` in `VoiceIQCore`: 143 passed.
- Scratch test (deleted after): `LocalSpeechInference.transcribeMeeting` with
  `diarizerDirectory: nil` on a 28 s eval clip returned 38 words, 0 segments,
  speakers `{"s1"}`; the encoded request round-trips with a nil diarizer.
- iOS simulator Release build, installed on iPad Air 11-inch (M4) and
  iPhone 18 Pro Max: Real-time toggle in its own section, no diarizer row,
  footer "Meetings use cloud transcription until Fluid Speech Mini is
  downloaded." while the model is missing (iPad) and no footer once it is
  downloaded (iPhone). Screenshots in `.amp/in/artifacts/`.

## Gaps

- No physical-device meeting run; the simulator cannot be fed meeting audio.
- The iOS in-process meeting decode still has no deadline (dictation has one).
- The Mac release build was not rebuilt; the Mac code path is unchanged apart
  from the optional wire field.
