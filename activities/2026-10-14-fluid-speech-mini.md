# 2026-10-14: Fluid Speech Mini replaces Parakeet v3 on device

## Why

The owner asked to replace the on-device Parakeet v3 model with Fluid Speech
Mini by FluidVoice (https://fluidvoice.com/labs/fluid-speech-mini), an English
fine-tune of Parakeet v3, by changing where the app downloads it. The post
reports 4.54% average WER against 4.86% for Parakeet v3, and 10.9% against
20.4% with another voice in the room, at 253 MB instead of 483 MB.

## What changed

- `ParakeetManifest.swift` now pins `FluidVoice-Labs/fluid-speech-mini-coreml`
  at `d81c3160dfe5a5e1f8f7267164a07d30617a3a1a`: 21 files, 252,710,832 bytes.
  Sizes and SHA-256 come from the commit tree (LFS) or from downloaded files
  checked against their git blob SHA-1.
- The model card says the package is a drop-in replacement for
  `parakeet-tdt-0.6b-v3-coreml`. The Core ML signatures confirm it: the
  preprocessor, encoder and decoder inputs and outputs match, and the
  preprocessor and `parakeet_vocab.json` are byte-identical. Two differences
  were handled:
  - FluidAudio 0.17.7 loads the v3 joint from `JointDecisionv3.mlmodelc`;
    the repository ships `JointDecision.mlmodelc`. The manifest installs the
    latter under the former name (`downloadURL` per file).
  - The new joint has no `top_k_ids`/`top_k_logits`. FluidAudio requests them
    because VoiceiQ decodes with `language: .english`, but it accepts both
    missing and then skips only its English script blocklist.
- The install folder stays `Models/parakeet-v3`, and the setting value stays
  `parakeet`. The existing stale-revision cleanup therefore deletes an
  earlier Parakeet v3 download (483.1 MB) and the row offers Download again;
  the user's model choice is kept.
- The name shown in Settings is "Fluid Speech Mini". Transcripts and usage
  now record `fluid-speech-mini-local` instead of `parakeet-v3-local`.
- `THIRD_PARTY_NOTICES.md` credits "Fluid Speech Mini by FluidVoice" as
  CC BY 4.0 requires. `docs/LOCAL_TRANSCRIPTION.md`, `docs/PRIVACY.md` and
  `docs/COST_TRACKING.md` were updated.

## Verification

- `scripts/release.sh`: 143 tests pass; the app and DMG are notarized
  (Accepted) and pass Gatekeeper.
- The notarized app was installed and launched on the Mac mini. Opening the
  model store removed the Parakeet revision `7dd20fe…`. The Settings row read
  "Download Fluid Speech Mini, 252.7 MB". The in-app download verified all
  files and published `parakeet-v3/d81c316…` with `.verified` and
  `JointDecisionv3.mlmodelc`.
- Five real recordings (5 to 157 s) were replayed through the installed
  helper (`.amp/in/replay-installed-helper.py`, file mode, no English tools)
  before and after. Every recording transcribed; cold load fell from 18.1 s
  to 14.7 s and warm loads stayed at 0.14 s. Differences:
  "make that a" became "make that Friday." (fix, the speaker said Friday);
  "Send the" became "Send a" in one take (likely a new error: the other
  takes of that sentence say "the"); "safer" became "saper" (unclear, the
  sentence suggests "separate"); two final periods were added. Five clips is
  too few to measure WER.
- On-device transcription was turned on only for the download and is off
  again; the selected model is still `parakeet`.

## Not verified

- A dictation through the full app with the English tools pack, which adds
  CTC dictionary rescoring.
