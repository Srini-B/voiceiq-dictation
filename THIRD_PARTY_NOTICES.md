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
| [FluidAudio](https://github.com/FluidInference/FluidAudio) 0.17.7 (Fluid Inference), with the `NemoTextProcessing` trait | Apache 2.0; bundled dependencies retain their upstream notices |
| [Sparkle](https://github.com/sparkle-project/Sparkle) (from M8) | Sparkle License (permissive, MIT-style) |

## Vendored libraries

### Optional Fluid Speech Mini model

- Fluid Speech Mini by FluidVoice: https://huggingface.co/FluidVoice-Labs/fluid-speech-mini-coreml, revision `d81c3160dfe5a5e1f8f7267164a07d30617a3a1a` (https://fluidvoice.com/labs/fluid-speech-mini).
- Built on NVIDIA Parakeet TDT 0.6B v3 (https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) and Moondream Parakeet Ultra, with the audio preprocessor from FluidInference's Parakeet v3 Core ML package.
- License: [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
- VoiceiQ downloads the model files unmodified, on explicit request; the joint
  network folder is saved as `JointDecisionv3.mlmodelc` instead of
  `JointDecision.mlmodelc`. Weights are not bundled with the app. File hashes
  are in `ParakeetManifest.swift`.

### Optional NVIDIA Nemotron 3.5 ASR Streaming 0.6B model

- Original model: https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b (NVIDIA).
- Core ML conversion: https://huggingface.co/FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML (Fluid Inference), revision `1a41b75758b0337ff67db7d5408280aaaf23074e`.
- License: [OpenMDW-1.1](https://openmdw.ai/license/1-1/).
- VoiceiQ downloads the converted `multilingual/2240ms/` files unmodified on
  explicit request. Weights are not bundled. File hashes are in `NemotronManifest.swift`.

### Optional NVIDIA Nemotron 3 Diarization model

- Original model: https://huggingface.co/nvidia/Nemotron-3-Diarization (NVIDIA).
- Core ML conversion: https://huggingface.co/FluidInference/nemotron-3-diarization-coreml (Fluid Inference), revision `25a90f97f254428d4b30374b76af9c74fdee8327`.
- License: [OpenMDW-1.1](https://openmdw.ai/license/1-1/).
- VoiceiQ downloads the converted `monolithic/v2/` offline bundle and
  `learnable_sil_emb.bin` unmodified on explicit request, for on-device meeting
  speakers. Weights are not bundled. File hashes are in `NemotronDiarizerManifest.swift`.

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

### NeMo text processing (inverse text normalization)

- Linked through FluidAudio's `NemoTextProcessing` trait into the Mac speech
  helper and the iOS app, not the Mac UI.
- Binary: `NemoTextProcessing.xcframework` from
  https://github.com/FluidInference/text-processing-rs release v0.3.1
  (Fluid Inference). License: Apache 2.0.
- Includes compiled weighted-FST grammars derived from
  https://github.com/NVIDIA/NeMo-text-processing (Copyright (c) NVIDIA
  CORPORATION & AFFILIATES), Apache 2.0. It statically links rustfst and
  flate2, each MIT OR Apache 2.0, and their MIT or Apache 2.0 dependencies.
  It contains no neural network weights.
- Full notice: `ThirdPartyLicenses/NemoTextProcessing-LICENSE.md` in the
  FluidAudio 0.17.7 source.

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
Google LLC. "OpenAI" and its logo are trademarks of OpenAI. "ElevenLabs" and its
logo are trademarks of ElevenLabs Inc. "TinyFish" and its logo are trademarks of
TinyFish. The iOS app bundles each service's favicon
(`iOS/App/Resources/Assets.xcassets/Provider*.imageset`) only to label the key
field for that service; no endorsement is implied. The app icon and menu bar
glyph are original works.
