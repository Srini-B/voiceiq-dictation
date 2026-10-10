# English speech processing for on-device dictation

## Cause and decision

Local Parakeet and Nemotron transcripts reached cleanup as bare decoder text.
Numbers, times, and currencies stayed in spoken form, user dictionary terms
did not reach the decoder, and noisy or long-silence recordings decoded as
recorded. Similar-sounding mistakes ("that" for "text") passed through.

Make on-device dictation English only and add three layers:

- Re-enable FluidAudio's `NemoTextProcessing` trait, which the app download
  size work had disabled. It is an FST grammar engine with no neural weights,
  linked only into the inference binary. Every local result now carries the
  original decoder text and a normalized candidate.
- Add an optional English tools pack (123,501,211 bytes, 21 files, three pinned
  Hugging Face commits) with LocalVQE noise reduction, Silero speech detection,
  and a Parakeet CTC 110M dictionary spotter. Each part fails open. The base
  model never needs the pack.
- Pass dictionary terms to the decoders. Nemotron biases decoding directly.
  Parakeet uses CTC rescoring from the pack.

Cleanup, Ask Anything, Translate, and Agent receive both texts. The original
stays available as evidence and the candidate is labeled as a suggestion. The
writing model must compare them rather than trust normalization alone. The
writing prompts also gained context-based correction rules for
similar-sounding words. Meetings are unchanged. No model or tools stay warm
between dictations.

The pack is a separate download rather than part of each model because both
models share it and Nemotron works without it. Its licenses (Apache 2.0, MIT,
CC BY 4.0) were confirmed from each pinned revision's Hugging Face metadata and
upstream sources; see `THIRD_PARTY_NOTICES.md`.

## Verification

- The release flow passed 143 existing tests and produced a signed,
  notarized app and DMG. The helper was tested from an installed copy.
- Nineteen replay scenarios passed across Parakeet, Nemotron real-time, and
  Nemotron file mode. They include original and noisy audio, exact-boundary
  stops, absent tools, rejected frame-count mismatches, and the 60-second
  idle exit. Startup audio retained "Once" and the final "memory".
- A 364.77-second recording repeated three sections. Both models returned all
  three sections and the final ending. Above five minutes, Parakeet uses its
  disk-backed path without optional audio processing. Nemotron keeps chunked
  noise reduction and skips VAD trim. Peak resident memory was not measured.
- The first replay exposed false dictionary insertions from Parakeet's
  permissive CTC rescue pass. Disabling that pass, removing the acoustic
  score bonus, and requiring 0.75 text similarity removed those insertions
  in the negative controls. This does not prove vocabulary accuracy in general.
- A synthetic spoken-number control produced "$25" and "12%". It also
  exposed an ambiguous time misnormalization. The original remains available
  to cleanup. When cleanup is off or skipped, the original is inserted.
- Direct service checks proved no cleanup call at exactly five seconds,
  a cleanup attempt above five seconds, and raw fallback when cleanup fails.
- macOS settings downloaded and deleted the real tools pack. Download,
  progress, and ready-state screenshots were inspected. User settings and the
  previously installed app were restored after verification.
- The unsigned iOS device archive and Release simulator build passed.
  iPhone and iPad settings screenshots show the full English-only note and
  aligned download actions. The iPhone downloaded the pack and displayed
  progress and its cancel icon. Both bundle audits found no neural weights.

Live cleanup-provider evaluation could not run because the probe had no
accessible API keys. Recognition is not perfect, and noise reduction did not
improve every phrase. No claim of accent accuracy or sub-three-second latency
is made. Physical iPhone and iPad inference has not been tested.

## Delivery and rollback

Local implementation; nothing published or installed on the MacBook.
Deleting the English tools pack from Settings returns local dictation to
base-model audio with Nemotron
dictionary biasing and normalization still active. Full rollback requires
reverting the source change; no data migration is needed. A downloaded pack
under `Models/english-tools/` is inert without the code.
