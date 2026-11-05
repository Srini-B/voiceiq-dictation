# 2026-11-05: Nemotron Unified ASR 0.6B evaluated, not adopted

## Why

The owner asked whether NVIDIA's Nemotron-Labs Unified ASR 0.6B should
become a third on-device model next to Fluid Speech Mini and Pro. The rule:
adopt it only if it is clearly more accurate (lower WER than Mini on both
LibriSpeech sets and not worse than Pro, or better on dictation-style
output), its speed and memory are acceptable, and dictionary correction
works.

## Decision

Not adopted. No app code changed.

- LibriSpeech test-clean is a tie (2.10 % against 2.05 % for Mini and Pro).
  Unified wins test-other (3.20 % against 3.77 % and 3.60 %).
- On natural conversational speech it is worse (13.0 % against 8.2 % and
  8.6 %). It drops words at the end of the audio and some short phrases in
  the middle, and it removes fillers and repeated words.
- On dictation-style output it is not better. 44 % of its transcripts end
  without a period or question mark (Mini: 11 %). On the saved dictations
  it ties with Mini and Pro.
- Speed, memory and dictionary correction are not a problem. They do not
  change the decision.

## The model

- Original: https://huggingface.co/nvidia/nemotron-labs-unified-asr-0.6b,
  OpenMDW-1.1, 25 European languages with punctuation and capitalization,
  encoder initialised from Parakeet TDT 0.6B v3. NVIDIA reports English WER
  4.68 (offline) against 4.93 for parakeet-tdt-0.6b-v3 on 7 English sets,
  and streaming at 0.16 to 2.08 s latency.
- Core ML: https://huggingface.co/FluidInference/nemotron-labs-unified-asr-0.6b-coreml,
  revision `bd13ddde81d3134719c520845346b3252daf3175` (2026-10-28),
  OpenMDW-1.1. The offline set (15 s encoder, RNNT decoder, single-step
  joint, `vocab.json` with 4,095 pieces) is 1,222,476,882 bytes with the
  fp16 encoder and 626,474,764 bytes with the int8 encoder. Mini is
  252.7 MB, Pro 1,228.4 MB. The streaming encoders (0.56, 1.12 and 2.08 s)
  are separate files of 595 MB (int8) or 1.19 GB (fp16) each.
- ML Program, spec 8, availability macOS 14 and iOS 17. It does not need
  macOS 15 or iOS 18.
- FluidAudio 0.18.2 runs it through `UnifiedAsrManager` with
  `UnifiedConfig(family: .nemotronMultilingual(.en))`, not `AsrManager`.
  FluidAudio notes that the int8 Unified encoder fails to load on A16
  iPhones (FluidAudio issue #828) and that int8 lost accuracy on French.

## Method

The same method as the 2026-11-05 dependency A/B. A scratch Swift package
under `.amp/in/eval/` (not committed) linked this checkout's
`VoiceIQInference` with FluidAudio 0.18.2 and ran it as a release build on
the M2 Mac mini (8 cores, 16 GB).

- Mini and Pro ran through the app's own entry point,
  `LocalSpeechInference.makeSession`, with a new session for each file, as
  the app does for each dictation (CPU encoder, in-memory path,
  `TextNormalizer`).
- Unified ran through `UnifiedAsrManager.transcribeWithTimings` with the
  encoder on the CPU, as `DictationCompute` sets for dictation. Language
  prompt `en`. The CTC rescoring was a verbatim copy of the app's
  `ParakeetVocabulary` (`ctcTokenRescore`, `cbw: 0`, `minSimilarity: 0.75`,
  spotter rescue off), followed by the same `TextNormalizer`.
- WER uses the final text the app would insert. Both reference and
  hypothesis go through Whisper's `EnglishTextNormalizer` (lowercase, no
  punctuation, numbers in one form for every model), then jiwer. Scoring
  the decoder text before `TextNormalizer` gives the same order.
- Another agent's job held the load average between 20 and 45 during the
  WER runs, so speed comes from separate runs at a load average of about 2.

Audio:

- LibriSpeech test-clean: every 8th utterance, 328 utterances, 6,535 words,
  40 min. test-other: every 9th utterance, 327 utterances, 5,939 words,
  37 min. Each utterance is a separate file of 1.4 to 32.9 s.
- Dictations: the 26 recordings that still have saved audio in
  `~/Library/Application Support/VoiceiQ/recordings` (7.9 to 53.9 s,
  2,216 words). The dependency A/B's "24 newest dictations" were most
  likely 24 of these. They are `say` test dictations played into the
  loopback input, not the owner's voice. The app has no saved audio of the
  owner's own dictations. The reference is the transcript saved with each
  recording, from cloud Nemotron 3.5 Transcribe for 20 of them and from
  Mini or Pro for the other 6.
- Natural speech: 20 segments of 6.9 to 21.8 s (783 words) from two
  meetings the app recorded from played recordings (an AMI design meeting
  and a GitLab team sync). The reference is the saved cloud transcript, so
  absolute numbers are rough and only the comparison counts.
- Dictionary: seven `say` clips (Samantha, Daniel and Karen voices) with a
  12-term dictionary (VoiceiQ, Srini, Tailscale, BlueLobster, Priya,
  FluidAudio, Parakeet, Nemotron, Sarvam, GitButler, Supabase, Kubernetes),
  19 term occurrences.

## Results

| | Mini | Pro | Unified fp16 | Unified int8 |
|---|---:|---:|---:|---:|
| test-clean WER | 2.05 % | 2.05 % | 2.10 % | 2.10 % |
| test-other WER | 3.77 % | 3.60 % | 3.20 % | 3.23 % |
| Meeting segments WER | 8.17 % | 8.56 % | 13.03 % | 12.90 % |
| Same, 0.6 s silence appended | 8.43 % | 8.17 % | 10.86 % | not run |
| 26 dictations, against saved transcript | 2.26 % | 2.17 % | 2.57 % | 2.57 % |
| Transcripts ending in . ? ! (701) | 622 | 615 | 391 | 393 |
| Dictionary terms right, without / with | 4 / 19 → 11 / 19 | 4 / 19 → 12 / 19 | 6 / 19 → 13 / 19 | 6 / 19 → 13 / 19 |
| First load from a fresh copy + first decode | 3.30 + 0.25 s | 4.24 + 0.25 s | 3.87 + 0.26 s | 3.37 + 0.26 s |
| Later load / decode of a 10.3 s clip | 0.03 / 0.24 s | 0.03 / 0.23 s | 0.00 / 0.26 s | 0.00 / 0.26 s |
| Real-time factor (10.3 s clip) | 43x | 44x | 40x | 40x |
| Max RSS / peak footprint, 10.3 s clip | 1,339 / 75 MB | 1,309 / 75 MB | 1,307 / 79 MB | 1,307 / 79 MB |
| Max RSS / peak footprint, test-clean run | 1,497 / 217 MB | 1,466 / 216 MB | 1,331 / 91 MB | 1,327 / 86 MB |
| Download | 252.7 MB | 1,228.4 MB | 1,222.5 MB | 626.5 MB |

On the CPU, int8 runs at the same speed and RSS as fp16, so its only gain
there is the smaller download. With the Neural Engine allowed (the
meetings setting), int8 needs 12.1 s to compile the first time and then
decodes 10.3 s of audio in 0.11 s. fp16 took 4.2 s to load and decoded no
faster than on the CPU. Mini's palettized encoder also uses about 1.3 GB of
RSS on the CPU, so the 1.2 GB of fp16 weights cost no more memory than
Mini.

The iOS Simulator runs Core ML on the Mac's CPU, so it would not show
iPhone memory or speed. It was not run because the accuracy results
already decided against the model. iPhone memory was not measured.

## Examples

Unified does better on several names (no dictionary):

- "Srini asked whether the tailscale note on Blue Lobster…"; Mini and Pro:
  "Shrini … tail scale note…".
- "Sarvam transcribed the Hindi meeting"; Mini: "Savim", Pro: "Savam".
- Newest saved dictation: "The meeting with Priya moved to Thursday at 3";
  Mini and Pro: "PRIA".
- "Nemotron" (Mini and Pro: "Nematron"); "before lunch" (Mini and Pro:
  "before launch").

Unified does worse in these ways:

- No final period: "Send the revised report to Priya by Friday, and copy
  the whole design team" and "That is everything for now. Thank you" (Mini
  and Pro end both sentences with a period).
- Words lost at the end of a segment: "…from the back end, R" (Mini:
  "…from the back end, uh, Rob."); "…that would be the main priority for
  me" (Pro: "…for me this week."). Appending 0.6 s of silence
  recovers part of this (13.0 % to 10.9 %), not all.
- Words lost mid-segment: "So we'll prioritize the snowplit overs as
  possible" (Mini: "…the snowplas switchovers as fast as possible");
  "Uh yeah, thank you. Uh, maybe you can guess…" became "Uh maybe you can
  guess…".
- Cleaned speech: fillers and false starts are removed ("Uh, no, just that
  it works nicely and I'm excited to, yeah, get this…" became "No, just
  that it works nicely and I'm excited to get this…"). Repeated words are
  merged ("again again" became "again", "help help" became "help" in
  LibriSpeech).
- Other: "Prier" for Priya, "long-hands-free dictation", "so, please".

## Dictionary correction

The app's CTC rescoring works on Unified's text and token timings without
changes. Seven of the 19 term occurrences changed to the dictionary
spelling, as many as with Mini: "Voice AEQ" to "VoiceiQ" (2 clips), "Blue
Lobster" to "BlueLobster", "Parakeek" to "Parakeet", "Voice EQ" to
"VoiceiQ", and "Git Butler" to "GitButler" (2 clips). One change damaged
the text: "Can you open a Git Butler branch" became "Can you open GitButler
branch", so the article was lost. Mini and Pro did not change that clip.
With only the owner's dictionary (VoiceiQ), no model corrected "Voice AEQ"
in the newest saved dictation.

## Not covered

- Long recordings over five minutes. `UnifiedAsrManager` has no disk-backed
  path, so the app would need one for parity.
- Streaming (live preview) encoders, non-English languages, `auto`
  language detection, a real microphone, and the owner's own voice.
- iPhone memory and speed.

## Verification

Nothing in the app changed, so `scripts/test.sh` and a release build were
not needed. The scratch package, audio and model downloads stayed under the
ignored `.amp/in/`.
