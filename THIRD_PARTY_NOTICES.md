# Third-party notices

## Fonts

### Google Sans Flex
- File: `App/Resources/Fonts/GoogleSansFlex/GoogleSansFlex-Regular.ttf` (variable font), with an
  identical copy and license in `iOS/App/Resources/Fonts/` for the iPhone app
- Copyright: Google LLC / Font Bureau (David Berlow)
- License: SIL Open Font License 1.1 — see `App/Resources/Fonts/GoogleSansFlex/OFL-GoogleSansFlex.txt`
- Source: served via Google Fonts (fonts.google.com/specimen/Google+Sans+Flex); binary
  pinned in-repo. The font is used unmodified (the OFL Reserved Font Name clause
  requires renaming if modified).

### Google Sans Code
- File: `App/Resources/Fonts/GoogleSansCode/GoogleSansCode-VF.ttf` (variable font, v7.001)
- Copyright: Google LLC
- License: SIL Open Font License 1.1 — see `App/Resources/Fonts/GoogleSansCode/OFL-GoogleSansCode.txt`
- Source: github.com/googlefonts/googlesans-code (release v7.001), unmodified.

## Sounds

None — no third-party audio ships in this app. The earcons are original works,
synthesized from scratch by `scripts/generate-earcons.py` (sine fundamentals plus
soft harmonics; no samples, no recorded material) and covered by this
repository's Apache 2.0 license. See `App/Resources/Sounds/ATTRIBUTION.md`.

## Swift packages

| Package | License |
|---|---|
| [Sauce](https://github.com/Clipy/Sauce) (Clipy) | MIT |
| [GRDB.swift](https://github.com/groue/GRDB.swift) (Gwendal Roué) | MIT |
| [FluidAudio](https://github.com/FluidInference/FluidAudio) 0.18.2 (Fluid Inference), with the `Diarizer` trait | Apache 2.0; bundled dependencies retain their upstream notices |
| [Sparkle](https://github.com/sparkle-project/Sparkle) (from M8) | Sparkle License (permissive, MIT-style) |

## Vendored libraries

### Optional Fluid Speech Mini model

- Fluid Speech Mini by FluidVoice: https://huggingface.co/FluidVoice-Labs/fluid-speech-mini-coreml, revision `d81c3160dfe5a5e1f8f7267164a07d30617a3a1a` (https://fluidvoice.com/labs/fluid-speech-mini).
- Built on NVIDIA Parakeet TDT 0.6B v3 (https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) and Moondream Parakeet Ultra, with the audio preprocessor from FluidInference's Parakeet v3 Core ML package.
- License: [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). Credit: "Fluid Speech Mini by FluidVoice".
- VoiceiQ downloads the model files unmodified, on explicit request; the joint
  network folder is saved as `JointDecisionv3.mlmodelc` instead of
  `JointDecision.mlmodelc`. Weights are not bundled with the app. File hashes
  are in `ParakeetManifest.swift`.

### Optional Fluid Speech Pro model

- Fluid Speech Pro by FluidVoice (Core ML): https://huggingface.co/FluidVoice-Labs/fluid-speech-pro-coreml, revision `3b9d38a93d606f84011e5a0a669b7ea146375a22` (https://huggingface.co/FluidVoice-Labs/fluid-speech-pro).
- Built on NVIDIA Parakeet TDT 0.6B v3 (https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) and Moondream Parakeet Ultra (https://huggingface.co/moondream/parakeet-ultra).
- License: [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). Credit: "Fluid Speech Pro by FluidVoice".
- VoiceiQ downloads the model files unmodified, on explicit request; the joint
  network folder is saved as `JointDecisionv3.mlmodelc` instead of
  `JointDecision.mlmodelc`. Weights are not bundled with the app. File hashes
  are in `FluidSpeechProManifest.swift`.

### Optional speaker separation model (pyannote community-1)

- Original pipeline: https://huggingface.co/pyannote/speaker-diarization-community-1
  (pyannote), with speaker segmentation by Plaquet and Bredin ("Powerset
  multi-class cross entropy loss for neural speaker diarization", Interspeech
  2023), the WeSpeaker speaker embedding (Wang et al., "Wespeaker: A research
  and production oriented speaker embedding learning toolkit", ICASSP 2023),
  and PLDA parameters from Brno University of Technology / BUT Speech@FIT for
  VBx clustering (Landini et al., Computer Speech & Language, 2022).
- Modified: Core ML conversion by Fluid Inference, https://huggingface.co/FluidInference/speaker-diarization-coreml,
  revision `df2625ac79a7ac6b65ad868fee6d80f320da4232` (fixed input shapes,
  mixed-precision storage, the FBank frontend split from the embedding model).
- License: [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/), as the
  repository's `NOTICE.md` scopes it to `Segmentation.mlmodelc`,
  `FBank.mlmodelc`, `Embedding.mlmodelc`, `PLDA.mlmodelc`, `PldaRho.mlmodelc`,
  `plda-parameters.json` and `xvector-transform.json`. VoiceiQ downloads only
  files from that set.
- VoiceiQ downloads `Segmentation`, `FBank`, `Embedding` and `PldaRho`
  (`.mlmodelc`) and `plda-parameters.json` unmodified on explicit request, for
  on-device meeting speakers. Weights are not bundled. File hashes are in
  `SpeakerDiarizerManifest.swift`.

### Optional English tools pack

VoiceiQ downloads these Core ML conversions unmodified, on explicit request, as
one pack. No weights are bundled with the app. File hashes are in
`EnglishToolsManifest.swift`.

- **Silero VAD v6.2.1 (speech detection).** Original model:
  https://github.com/snakers4/silero-vad (Copyright (c) 2020-present Silero Team),
  via https://huggingface.co/onnx-community/silero-vad. Core ML conversion:
  https://huggingface.co/FluidInference/silero-vad-coreml (Fluid Inference),
  revision `b419383c55c110e2c9271fa6ee0ea83d03c70d96`. License: MIT.
- **Parakeet TDT-CTC 110M, CTC branch (dictionary correction).** Original
  model: https://huggingface.co/nvidia/parakeet-tdt_ctc-110m (NVIDIA). Core ML
  conversion with tokenizer and vocabulary files:
  https://huggingface.co/FluidInference/parakeet-ctc-110m-coreml (Fluid
  Inference), revision `accdafd8cf8a2ff1cabe3c11e54416b405d409aa`. License:
  [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).

### WebRTC audio processing (AEC3 echo canceller)
- File: `VoiceIQCore/Vendor/WebRTCAEC/CVoiceIQAEC.xcframework` (static library, arm64 and x86_64)
- Source: https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing at `d0569cfa50c1858ee279d77b3fc8870be6902441`, built by `VoiceIQCore/Vendor/WebRTCAEC/build.sh` together with VoiceiQ's own bridge (`bridge/voiceiq_aec.cc`, Apache 2.0)
- Licenses: WebRTC BSD 3-Clause plus its patent grant; Abseil Apache 2.0; PFFFT, Ooura FFT, the WebRTC FFT, and the square-root routine under their BSD-style terms. Full texts are in `VoiceIQCore/Vendor/WebRTCAEC/Notices/`.

## Adapted source

### Dictus (iOS host-app return)

- Files: `iOS/Keyboard/Sources/HostAppResolver.swift`,
  `iOS/Keyboard/Sources/HostArbiterActivation.{h,m}`,
  `VoiceIQCore/Sources/Bridge/KnownAppSchemes.swift`
- Source: [getdictus/dictus-ios](https://github.com/getdictus/dictus-ios), adapted
- License: MIT

```
MIT License

Copyright (c) 2026 PIVI Solutions

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### VivaDicta (return URL table)

- File: `VoiceIQCore/Sources/Bridge/KnownAppSchemes.swift`. Dictus ported the
  table of app return URLs and hosts with no way back from VivaDicta; ours
  takes Dictus's copy and VivaDicta's later additions (synced 2026-11-05).
- Source: [n0an/VivaDicta](https://github.com/n0an/VivaDicta)
  (`VivaDicta/VivaDictaApp.swift`), adapted
- License: MIT

```
MIT License

Copyright (c) 2026 Anton Novoselov

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### Hex (Mac dictation behaviour)

- Files: `VoiceIQCore/Sources/InsertionEngine/TypingInserter.swift` (typing
  instead of pasting for Windows App and Chromium 155–156),
  `VoiceIQCore/Sources/AudioEngine/MediaPause.swift` (pausing Music and
  Spotify), the dropout padding in
  `VoiceIQCore/Sources/AudioEngine/AudioCaptureEngine.swift`, and the start
  tone's chord grace in `App/Sources/DictationController.swift`
- Source: [anomalyco/hex](https://github.com/anomalyco/hex) at `2a023f91`
  (`src/paste.rs`, `src/keyboard.rs`, `src/audio/recording_environment.rs`,
  `src/dictation.rs`, `src/feedback.rs`), rewritten in Swift
- Also `VoiceIQCore/Sources/AudioEngine/MacLid.swift` (the closed-lid check),
  from Hex at `afd7da22` (`src/audio/lid.rs`), rewritten in Swift
- Also the iPhone microphone choice in
  `iOS/App/Sources/Support/MobileSettings.swift` and
  `iOS/App/Sources/Session/KeepAliveAudio.swift` (input order per choice,
  Bluetooth hands-free only for Bluetooth, the warm session on the iPhone's
  mic), from Hex at `afd7da22` (`ios/HEXShared/MicrophoneChoice.swift`),
  rewritten in Swift
- Also, from Hex at `afd7da22`, rewritten in Swift: the spoken-order insert
  queue (`VoiceIQCore/Sources/SessionCoordinator/InsertTurns.swift`, from
  `OrderedOutputs` in `src/parakeet.rs`), Press Return after pasting
  (`VoiceIQCore/Sources/InsertionEngine/ReturnAfterPaste.swift`, from
  `src/dictation/yolo_mode.rs`), the calendar reader
  (`VoiceIQCore/Sources/MeetingEngine/CalendarMeetings.swift`, from
  `src/calendar.rs`) and the sound volume setting (`src/feedback.rs`)
- Also, from Hex at `db515bda`: `VoiceIQCore/Speech/SpokenNumbers.swift`
  (numbers as digits, from `ios/HEXShared/Formatting/SpokenNumbers.swift`,
  added in `06ac30af` and `339a5caa`) and
  `VoiceIQCore/Sources/FormattingPipeline/SoundAlikeSpelling.swift`
  (Dictionary sound-alike spellings, from
  `ios/HEXShared/Spelling/SoundAlikeSpelling.swift`, added in `165fa676`),
  adapted with their test cases in
  `VoiceIQCore/Tests/VoiceIQCoreTests/OnDeviceTextTests.swift`; and voice
  isolation (`492d8c28`: `src/voice_processing.swift`,
  `ios/HEXMobile/AudioBackend.swift`), rewritten in Swift in
  `AudioCaptureEngine.swift` and `KeepAliveAudio.swift`
- Also, from Hex at `012bdbbe`, rewritten in Swift: the macOS 27.3 posting
  grant in `VoiceIQCore/Sources/InsertionEngine/KeystrokeAccess.swift` and the
  checks that use it (`341046f8`: `src/paste.rs`, `src/paste/macos.rs`,
  `src/desktop/permission_guide.rs`), and the Privacy & Security list name for
  each macOS version (`0744db0d`: `native/permission_guide.m`)
- Also, from Hex at `a2d940e3`, rewritten in Swift: the iPhone shows a
  dictation as recording only once its first audio buffer arrives, and a stop
  before then cancels quietly (`ios/HEXKeyboard/KeyboardLocalDictation.swift`;
  here `DictationCoordinator.audioFlowing`, `iOS/App/Sources/AppModel.swift`);
  and from `9e41970e`, the cellular test on `NWPath` (`usesInterfaceType(.cellular)`,
  `isExpensive`, from `ios/HEXMobile/KeyboardParakeetDownload.swift`) in
  `VoiceIQCore/Sources/LocalModels/CellularDownloadConsent.swift`
- Also, rewritten in Swift: the middle-mouse hold
  (`VoiceIQCore/Sources/HotkeyEngine/MiddleMouseHold.swift` and its use in
  `EventTapEngine.swift`, from `dc0e6e7c`, `src/middle_mouse_dictation.rs`),
  the second ⌘Esc for long dictations
  (`VoiceIQCore/Sources/SessionCoordinator/CancelConfirmation.swift`, from
  `9d6e0990`, `src/dictation/cancel_confirm.rs`), and the pill's return to
  the active Space (`App/Sources/HUD/PillHUDController.swift`, from
  `8c9489b6`, `src/rune_hud/macos.rs`)
- Also, from Hex between `db515bda` and `012bdbbe`, rewritten in Swift:
  rebuilding the meeting system tap when the default output changes or the
  track goes to exact zeros, new tap before old, with the gap written as
  silence (`5704885d`, `4a3e9d49`: `src/meeting/capture.rs`,
  `src/meeting/macos.rs`, `src/meeting/macos/system_audio.rs`) in
  `VoiceIQCore/Sources/MeetingEngine/SystemAudioTap.swift` and
  `SystemTapWatch.swift`; never following an output-only device as the call
  mic (`657aa0cf`, `src/microphone_activity.rs`) and a browser call ending
  while the Mac is locked (`092a9b33`, `src/meeting/watcher/call_end.rs`) in
  `CallDetector.swift`; the meeting mic mute (`6118eb82`,
  `src/meeting/capture.rs`) in `MicTap.swift`; and the Aside browser's
  bundle ID (`ae1cdf71`, `src/meeting/detection.rs`) in `CallApps.swift`;
  and discarding a meeting while it records, after an inline confirmation
  (`01e5209b`, `src/rune_ui/meeting_capsules.rs` and `panel.rs`), in
  `MeetingEngine.swift` and `App/Sources/HUD/MeetingPillContent.swift`
- Also, from Hex at `01e5209b` and `4a3e9d49` (`src/rune_ui/list_detail.rs`,
  `src/rune_ui/meeting_capsules/panel.rs`), rewritten in Swift for VoiceiQ's
  Meetings window: Rename in the meeting's `…` menu, the prompt that Copy
  prompt for an AI agent writes (`AgentAPI.meetingPrompt`, pointing at
  VoiceiQ's MCP tools instead of Hex's CLI), and the warning on a call whose
  system audio was not heard (`MeetingEngine/SilentSystemAudio.swift`,
  which checks the saved track instead of reading the permission)
- Also, from Hex at `012bdbbe`, rewritten in Swift: the writing-Off tidy-up
  (`VoiceIQCore/Sources/FormattingPipeline/TidyStyle.swift`,
  `TidyText.swift` and `SpokenMarks.swift`, from `src/dictation/style.rs`,
  `style/spacing.rs`, `style/notes.rs`, `filler_words.rs`,
  `spoken_formatting.rs` and `spoken_symbols.rs`), and spoken email
  addresses (`SpokenAddresses.swift`, from
  `ios/HEXShared/Formatting/SpokenCleanupRules.swift`), adapted with Hex's
  test cases in `VoiceIQCore/Tests/VoiceIQCoreTests/TidyTests.swift`
- Also, from Hex at `a0f0a858` and `e27726790`, rewritten in Swift as rules
  with no model: the disfluencies the tidy-up removes and the words it keeps
  (`VoiceIQCore/Sources/FormattingPipeline/SpokenDisfluencies.swift`, from
  `ios/HEXShared/Formatting/CleanupGuard.swift` and its port
  `src/dictation/cleanup/guard.rs`, with `guard/context.rs` and the cases in
  `guard_tests.rs`)
- Also, from Hex at `f1c772c9`, rewritten in Swift: reading part of a
  meeting by time into it, keeping the turns that overlap the range whole and
  refusing a start that is not before the end (`OffsetRange` and
  `parse_offset` in `src/meeting/query.rs`), in
  `VoiceIQCore/Sources/MeetingEngine/TranscriptRange.swift` and `get_meeting`
- Also, from Hex at `ee9b069a`, rewritten in Swift: rewriting a meeting's
  Markdown file only while it still matches the hash of what the app last
  wrote, so the user's own edits are never overwritten
  (`src/meeting/notes_file.rs`, `src/meeting/write/markdown.rs`), in
  `VoiceIQCore/Sources/MeetingEngine/MeetingMarkdownFiles.swift`
- Also, from Hex at `b67dd262`, rewritten in Swift for the meetings
  evaluator only (no app code): the offline meeting pass's pause-cut
  chunks, word seams, quiet-microphone raise and echo suppression
  (`eval/meetings/Sources/LocalMeetingsEval/HexStyle.swift`, from
  `src/meeting/transcript.rs`, `src/meeting/chunk_level.rs`,
  `src/meeting/echo.rs` and `src/transcription/pause_segmenter.rs`)
- License: MIT

```
MIT License

Copyright (c) 2026 Christopher Langton

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### Hex (iOS typing keyboard)

- Files: everything under `iOS/Keyboard/Hex` (letters and number layers,
  suggestion bar, auto-correction, slide to type, emoji panel, trackpad
  cursor, the English typing model `en.hextm` and its spellings
  `en.spellings`), copied unchanged by
  `scripts/sync-hex-keyboard.sh` except for the patches in
  `iOS/Keyboard/Hex/patches`. The commit is in `iOS/Keyboard/Hex/UPSTREAM`
  (`f5819f4c`, 2026-11-27).
- Source: [anomalyco/hex](https://github.com/anomalyco/hex)
  (`ios/HEXShared/FullKeyboard`, `ios/HEXKeyboard`), MIT, the licence above;
  its text is also in `iOS/Keyboard/Hex/LICENSE`.
- Data inside it, per Hex's `ios/docs/acknowledgements.md`: `en.hextm` is
  built from Google Books Ngram (CC BY 3.0), SCOWL (including its names,
  days and places lists) and WordNet (permissive licences) and Hex's own word
  list (MIT). Words newer than the books and their spellings in `en.hextm` and
  `en.spellings` ("ChatGPT", "TikTok") come from the Leipzig Corpora
  Collection's English news downloads for 2023 to 2025
  (https://wortschatz.uni-leipzig.de/en/download/English), Leipzig University and
  the Saxon Academy of Sciences and Humanities in Leipzig (D. Goldhahn,
  T. Eckart and U. Quasthoff, LREC 2012), CC BY 4.0
  (https://creativecommons.org/licenses/by/4.0/); only word counts, how many
  sites use each word, and spellings are kept. `never-suggest.tsv` is curated
  from LDNOOBW (CC BY 4.0); `Emoji/emoji-index-en.txt` is built from
  Unicode's emoji-test.txt and CLDR (Unicode License v3, text in
  `iOS/Keyboard/Hex/FullKeyboard/Emoji/LICENSE-Unicode.txt`).
- No GPL code. Hex's other languages' word models and emoji indexes are not
  included (the Spanish model is MPL 1.1).

### FluidVoice (on-device meetings design)

- The on-device meeting path (`LocalMeetingJob`, and `LocalMeetingTranscriber`
  until 0.7.18, when meetings moved to the cloud only) follows FluidMeet's design: the meeting is transcribed after it ends by a
  Fluid Speech model, speakers are separated by a diarization model, and the
  two are joined by time.
- Source: [altic-dev/FluidVoice](https://github.com/altic-dev/FluidVoice)
  (`Sources/Fluid/Services/Meeting/`), GPLv3. VoiceiQ includes no FluidVoice
  source code; the design was reimplemented on FluidAudio.

### Voice Arena AMEND (dictation eval judge prompt)

- `eval/hard-audio/judge.py` adapts the AMEND v1 judge prompt and its text
  normalisation, with an added question about form. Eval tooling only; nothing
  from it ships in the app.
- Source: [VoiceArenaAI/AMEND](https://github.com/VoiceArenaAI/AMEND),
  Apache-2.0.

## Behaviour studied, no code used

### FluidVoice (dictation and meetings behaviours)

[altic-dev/FluidVoice](https://github.com/altic-dev/FluidVoice) is GPL-3.0,
so under the clean-room rule in `CONTRIBUTING.md` none of its code is copied,
translated or paraphrased here. VoiceiQ reimplemented these behaviours, seen
at `87fbef8b`, from a written description: no paste when focus is on a
control that takes no text, waking any Electron app's accessibility,
ignoring the dictation key at the lock screen, F13–F19 as keys of their own,
dictionary spellings in meeting transcripts, a 30-minute quiet time after
dismissing a call offer, VoiceOver announcements for the pill, ⌘C in
History, reading a field back after a paste to catch a ⌘V that missed
(`PasteCheck.swift`), and stopping a detected call's recording after a
countdown once the call ends (`MeetingEngine.watchForCallEnd`).

## Trademarks

"AssemblyAI" is a trademark of AssemblyAI, Inc. "Google" and "Gemini" are
trademarks of Google LLC, "OpenAI" of OpenAI, "ElevenLabs" of ElevenLabs,
and "Claude" of Anthropic, PBC; Cost Analysis names the last four only to
label spend from when they were providers. No endorsement is implied. The app icon and menu bar glyph are
original works. "NVIDIA" and "Parakeet" are trademarks of NVIDIA Corporation, and
"FluidVoice" and "Fluid Speech" are Altic's product names; the model credits above are
attribution, not endorsement.
