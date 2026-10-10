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
| [FluidAudio](https://github.com/FluidInference/FluidAudio) 0.17.7 (Fluid Inference) | Apache 2.0; bundled dependencies retain their upstream notices |
| [Sparkle](https://github.com/sparkle-project/Sparkle) (from M8) | Sparkle License (permissive, MIT-style) |

## Vendored libraries

### Optional NVIDIA Parakeet TDT 0.6B v3 model

- Original model: https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3 (NVIDIA).
- Core ML conversion: https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml (Fluid Inference), revision `7dd20fe6b1797d35f5e3307e8b1732d9a178edfe`.
- License: [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
- VoiceiQ downloads the converted model files unmodified, on explicit request.
  Weights are not bundled with the app. File hashes are in `ParakeetManifest.swift`.

### Optional NVIDIA Nemotron 3.5 ASR Streaming 0.6B model

- Original model: https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b (NVIDIA).
- Core ML conversion: https://huggingface.co/FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML (Fluid Inference), revision `1a41b75758b0337ff67db7d5408280aaaf23074e`.
- License: [OpenMDW-1.1](https://openmdw.ai/license/1-1/).
- VoiceiQ downloads the converted `multilingual/2240ms/` files unmodified on
  explicit request. Weights are not bundled. File hashes are in `NemotronManifest.swift`.

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

## Trademarks

"Google", the Google logo, the Gemini spark, and related marks are trademarks of
Google LLC. This repository ships no Google logo assets; the app icon and menu bar
glyph are original works.
