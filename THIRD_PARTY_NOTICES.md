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
| [Sparkle](https://github.com/sparkle-project/Sparkle) (from M8) | Sparkle License (permissive, MIT-style) |

## Vendored libraries

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
- Also the check that stops a dictation's text that answers the speaker or
  adds a preamble (`VoiceIQCore/Sources/FormattingPipeline/HeardGuard.swift`),
  adapted from the cleanup rejection rules in `src/dictation/apple_cleanup.rs`
  at `6f0b20c1`, rewritten in Swift
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

## Behaviour studied, no code used

### FluidVoice

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

"Google", the Google logo, the Gemini spark, and related marks are trademarks of
Google LLC. "OpenAI" is a trademark of OpenAI, "ElevenLabs" of ElevenLabs,
and "Claude" of Anthropic, PBC; Cost Analysis names them only to label spend
from when they were providers. The iOS app bundles the Gemini favicon
(`iOS/App/Resources/Assets.xcassets/ProviderGemini.imageset`) only to label
the key field; no endorsement is implied. The app icon and menu bar glyph are
original works.
