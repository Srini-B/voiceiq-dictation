# 2026-11-07: Fluid Speech Pro updated to upstream 36481f6

## Why

On 2026-11-05 FluidVoice updated `FluidVoice-Labs/fluid-speech-pro` at
36481f6c9d353a301df1524dd0124eaf9212713e ("Update the model and add its
leaderboard results"). Our Core ML package was built from 53f490b. The owner
asked whether the apps need the update, for Pro and for Mini.

## What changed upstream

The two `.nemo` checkpoints were compared tensor by tensor:

- The encoder, tokenizer and vocabulary are byte-identical.
- All 15 decoder and joint tensors were retrained: `decoder.prediction.*`
  and `joint.enc`, `joint.pred` and `joint.joint_net.2`. Every element moved,
  with a relative L2 change of 0.1–1.6%.
- The checkpoint also carries the clean-mode adapter (`clean_mode.*`, 530
  tensors). The new `fluid_speech.load` leaves it out unless `clean_mode=True`,
  so the converter needed no logic change, and we still ship the plain model.
- FluidVoice now reports a mean WER of 5.43 on the Open ASR leaderboard. It
  published no number for 53f490b.

Fluid Speech Mini has no update. `FluidVoice-Labs/fluid-speech-mini-coreml`
still has one commit, d81c316 (2026-10-13), which `ParakeetManifest.swift`
pins. Its onnx and gguf siblings are unchanged too.

## What we did

- `scripts/fluid-speech-pro-coreml/` is pinned to 36481f6: the `.nemo`
  SHA-256 and the `fluid_speech.py` git hash. `setup.sh` now downloads again
  when a cached `.nemo` does not match the pinned hash.
- Reconverted on the Mac mini, in thread
  https://ampcode.com/threads/T-01a1b53e-bc62-76b8-9fbf-f50ea7f15807, and
  uploaded as `cyron/fluid-speech-pro-coreml@42d66fdd64541b88cf70223701f59e76b766567c`.
  Its parent is ec52e16, which is kept.
- Compared with ec52e16, only the decoder and joint `weight.bin` files changed,
  plus the small `coremldata.bin` and `metadata.json` files that record the
  source revision. The total is still 21 files and 1,228,362,429 bytes.
- `FluidSpeechProManifest.swift`, `THIRD_PARTY_NOTICES.md` and
  `docs/LOCAL_TRANSCRIPTION.md` now point at the new revisions.

## Verification

- **Parity against NeMo, 15 clips.** Encoder relative L2 0.88% and 0.98%,
  decoder 0.78%, joint `token_id` agreement 99.7–100%. These match the first
  conversion. Core ML matched PyTorch on the same window on all 15 clips.
- **FluidAudio 0.17.7 smoke test.** Loads in 1.24 s, transcribes all 32 rows,
  and CPU and ANE give the same text.
- **Old vs new WER**, 349 random utterances from the Open ASR leaderboard
  parquets, Whisper normaliser:

  | Set | Old | New |
  |---|---|---|
  | LibriSpeech test-clean | 1.39 | 1.36 |
  | AMI | 8.30 | 8.38 |
  | Earnings-22 | 9.82 | 10.02 |
  | Pooled | 4.64 | 4.68 |

  The difference is 2 word errors out of 5,147, which is within noise.
  Core ML matches NeMo fp32 on the new model. On our own dictation clips the
  text is identical.
- **Upload.** All 24 files match the HF tree at 42d66fd.
- **Mac app.** Signed and notarized build, updated in the app from a real
  Nov 2 install of ec52e16: see the Mac thread.

## Model updates keep the old model working

The first plan was to let the bump work as earlier bumps had: the first launch
of the new app removes the ec52e16 folder, and the Pro row shows Download
again. The owner rejected that. A user who starts a dictation after updating
the app would find their model gone. Pinned model updates now work like this
(`docs/LOCAL_TRANSCRIPTION.md`):

- A manifest lists compatible earlier revisions in `previousRevisions`. Pro
  lists ec52e16.
- One of those on disk stays in use, and the row offers "Update (size)".
- Update clones the unchanged files and downloads only the rest. For this
  update that is the decoder and joint weights plus the small files, about
  36 MB rather than 1.23 GB, because the 1.19 GB encoder is unchanged.
- New sessions switch only after every file verifies. Cancel or failure keeps
  the old model.
- Revisions not listed, and models named in `replaces`, are still removed at
  launch as before.

## Rollout and rollback

Users get the update offer once they install the next app release, and keep
dictating on ec52e16 until they tap Update.

To roll back, pin ec52e16 and its entries again. That revision stays on HF.
A user who already updated would then be offered ec52e16 as a fresh
download, unless 42d66fd is added to its `previousRevisions`.
