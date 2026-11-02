# 2026-11-02: Fluid Speech Pro replaces on-device Nemotron 3.5 (Mac)

## Why

The owner asked to replace the on-device Nemotron 3.5 ASR Streaming model
with Fluid Speech Pro by FluidVoice
(https://huggingface.co/FluidVoice-Labs/fluid-speech-pro), converted to
16-bit Core ML, on macOS only. FluidVoice publishes Pro only as a NeMo
checkpoint (2.52 GB), so the app cannot load it as published.

## Conversion

- Pro is Parakeet TDT 0.6B v3 (via Moondream Parakeet Ultra) plus one
  residual block, `encoder.fv_insert`, run as a hook after subsampling.
  Decoder, joint and vocabulary keep the v3 shapes, so a converted package
  is a drop-in for FluidAudio 0.17.7's `.v3` loader, as Fluid Speech Mini is.
- `scripts/fluid-speech-pro-coreml/` holds the rerunnable conversion: it
  loads the model with FluidVoice's `fluid_speech.load` (attaches the block,
  strict load), traces mobius' Parakeet v3 wrappers (FluidInference/mobius
  `588b8e7`), converts all four parts with fp16 weights and compute (no
  palettization or quantization, macOS 15 / iOS 18 target) and compiles
  them. Python 3.11, torch 2.7.0, coremltools 9.0, nemo-toolkit 2.4.0.
  Clean mode is not included; cleanup already removes fillers.
- Result: 21 files, 1,228,362,429 bytes (Mini: 252.7 MB, palettized).
  Mini's layout, `JointDecisionv3.mlmodelc` included; unlike Mini's, the
  joint has `top_k_ids`/`top_k_logits`. `parakeet_vocab.json` is
  byte-identical to Mini's.
- Published at https://huggingface.co/cyron/fluid-speech-pro-coreml (public,
  CC BY 4.0, credited "Fluid Speech Pro by FluidVoice. Built on NVIDIA
  Parakeet TDT 0.6B v3 and Moondream Parakeet Ultra"), revision `ec52e16204b3d2c4c8bf60e576728fc58a825689`.
  The first upload used the Xet transfer path, ran at about 0.4 MB/s and
  hung with only CLOSE_WAIT sockets; `HF_HUB_DISABLE_XET=1` uploaded at
  about 5 MB/s.

## Conversion checks (`verify_fluid_speech_pro.py`)

- The compiled encoder holds all 8 `fv_insert` weights and its one GELU.
  The traced encoder equals the eager encoder with the block (max difference
  0). Core ML on CPU is 0.88% relative L2 from PyTorch with the block and
  2.75% from PyTorch without it, on the 15 s trace clip.
- Joint `token_id` agrees 100% with PyTorch over 1,004 and 465 frame and
  state pairs; durations agree 99.8% and 100%.
- Transcripts on five real dictations, a French and a German `say` clip and
  a 27.8 s joined clip: the Core ML pipeline equals PyTorch on the same 15 s
  window on all 8, and NeMo `transcribe` on 7. The eighth ends mid-word, and
  PyTorch on the zero-padded window gives the same different last word, so
  the padding causes it, not the conversion.
- Core ML places all 1,393 encoder ops on the CPU even when the ANE is
  allowed (Mini's palettized encoder gets 1,681 ANE ops). The app already
  pins dictation encoders to `.cpuOnly`.

## App changes

- `LocalSpeechModel.nemotron` became `.fluidSpeechPro` ("Fluid Speech Pro",
  `fluid-speech-pro-local`, Parakeet v3's 25 languages), offered on the Mac
  only. `LocalSpeechModel(stored:)` reads a stored `nemotron` as Pro.
- Pro runs through `ParakeetSession`, with the same live preview as Mini.
  No `language` is passed to FluidAudio any more: it only filters the
  joint's top-K tokens by script. Mini's joint has no top-K, so it never
  applied there; with Pro, `.french` turned "ce soir" into "ce sort" and
  `.english` would block Cyrillic and Greek. English number formatting and
  the English tools run only for an English language choice.
- Removed `NemotronSession`, `NemotronOnsetRecovery`, `SpeechBoundaries`,
  `NemotronManifest`, the speech detector load in `EnglishTools`, the strict
  (stream-is-the-transcript) path in `LocalTranscriber`, and the rule that
  selecting Nemotron turned real-time on. The English tools pack keeps its
  unused `vad` folder; changing the pack would make every install download
  its 103.9 MB again.
- `LocalModelManifest.replaces`: opening the Pro store deletes the retired
  `Models/nemotron-3.5-multilingual-2240ms` folder (664.8 MB).

## Verification

- `scripts/test.sh`: 143 tests pass. `scripts/build-ios.sh` builds.
- First signed and notarized 0.6.21 build (`SKIP_TESTS=1
  scripts/release.sh`, app and DMG accepted), installed to `/Applications`,
  Gatekeeper accepted. Before the upload finished, its manifest used a
  placeholder revision and the converted package was copied in by hand.
- Opening Settings deleted the old Nemotron folder. Settings → Dictation
  showed Fluid Speech Mini ("Languages: English") and Fluid Speech Pro;
  selecting Pro stored `fluidSpeechPro` and showed its Language menu.
- Installed helper replay (`fluidSpeechPro` and `parakeet`, file and
  streaming): English, French and German clips transcribed as in the
  conversion checks; Pro's first load 4.8 s, later loads 0.04 s, decode
  0.2 to 0.8 s after stop for 6 to 28 s of audio.
- Two hands-free dictations in the installed app, `say` audio played into
  the Jump Desktop Microphone: usage booked `transcribe
  fluid-speech-pro-local` then Claude cleanup; the helper logged
  `encoder=cpu`, 7.9 s decoded in 0.40 s and 15.4 s in 0.65 s. The pill
  showed Pro's live preview mid-sentence ("…n the Mac Mini, and the words
  should appear in the pill"). Both recordings lost their last word or two
  because the playback tool stopped early; Mini gave the same words on the
  saved audio.
- "Hide pill from screen sharing" was turned off for the pill capture and
  back on afterwards.
- Second notarized build, pinned to revision `ec52e16`: opening Settings
  removed the hand-placed folder, the Pro row read "Download (1.23 GB)", and
  the in-app download fetched 1.2 GB, verified every file's SHA-256 and
  published `Models/fluid-speech-pro/ec52e16…` with its marker. A dictation
  then loaded it in 1.05 s and booked `fluid-speech-pro-local`.
- The Mac mini's selected model was put back to Fluid Speech Mini, its
  choice before the test; Pro stays downloaded.

## Not verified

- A real microphone, accuracy on more than these clips, any non-Latin
  language, and a true cold start after reboot.
- Memory on an 8 GB Mac with the 1.2 GB encoder loaded.

## Rollback

Revert the branch. Stored `fluidSpeechPro` choices then read as unknown and
fall back to Fluid Speech Mini; the `Models/fluid-speech-pro` folder stays
until deleted from Settings or by hand. The Nemotron folder is already gone
on Macs that opened the Pro store and would need downloading again.
