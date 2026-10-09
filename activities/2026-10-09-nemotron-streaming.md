# Nemotron multilingual streaming

Added a selectable on-demand Nemotron 3.5 model beside Parakeet for macOS,
iPhone and iPad dictation. Meetings remain unchanged. The download pins the
664,846,846-byte full-vocabulary 2240 ms Core ML bundle. The model card recommends
this tier for multilingual throughput. Model hashes and revision are in
`NemotronManifest.swift`; usage and fallback rules are in
`docs/LOCAL_TRANSCRIPTION.md`.

Selecting Nemotron enables real-time once. Users can turn it off afterwards;
Nemotron can process saved audio too. Parakeet remains file-based. Missing selected
models use the cloud rather than silently switching to another local model.
Models release after recognition. The Mac helper exits after 60 idle seconds.

## Verification

- 143 existing core tests passed. No permanent tests were added.
- Signed, notarized Release built with `scripts/release.sh`, installed on the
  Mac mini. Nested signature and stapled ticket verified.
- iOS simulator build and unsigned device Release compile passed.
- Inspected settings on Mac, iPhone simulator and iPad simulator. Verified
  selection auto-enable, missing/downloaded states, both downloaded rows,
  inline cancel layout, and real-time off with Nemotron downloaded.
- iPad download cancellation returned to the Download state.
- Installed helper rejected missing stream bytes, saved frame-count mismatch,
  and absent model files. Idle process exit observed at 62.89 seconds.
- Physical iPhone/iPad model inference and complete stop-to-paste interaction
  were not measured in this run.

## MacBook comparison

Used the M1 MacBook recording `20261009-154744-F3EA34C4`, 121.590875 seconds,
1,945,454 mono 16 kHz frames. Ran the installed signed helper from a separate
verification app. Five alternating runs per model used fresh helper processes;
Nemotron PCM delivery followed wall-clock audio cadence. All 3,890,908 bytes
were accepted in each streaming run. Model loading began at recording start.

| Path | Runs | Median remaining ASR time | Range |
|---|---|---|---|
| Parakeet saved file | 5 | 1.562 s | 1.548–1.657 s |
| Nemotron streaming | 5 | 0.151 s | 0.121–0.165 s |
| Nemotron saved file | 1 | 3.330 s | Single run |

These measure final transcription work, not end-to-end dictation. Nemotron
does most inference while speech arrives. Parakeet waits for the completed CAF.
Capture finalization, cleanup and paste are outside these numbers. Mac capture
can add up to 1.5 seconds after stop. First observed model loads took 28.54 seconds
for Parakeet and 21.11 seconds for Nemotron; later loads were about 0.15 and 0.22
seconds. Core ML preparation is a suspected explanation, not an isolated finding.
Short first-use dictations therefore remain a latency risk.

Both transcripts preserved the main request but misheard technical terms.
Both rendered Parakeet as "packet" and "by us" as "bias". Nemotron additionally
rendered "which is" as "witches". Saved cleaned text is edited prose, not a
verbatim accuracy reference. No WER or general accuracy winner is claimed.

All comparative cleanup probes failed before a provider call because the remote
process could not access Keychain, status -25308. Their fast failures are excluded
from timings. The original history entry completed its pipeline in 6.458 seconds;
its successful Gemini 3.8 Flash cleanup transport took 4.705 seconds. That is
historical context, not a new Nemotron cleanup result.

A final read of 701 MacBook dictations with positive recorded pipeline times
gave a 5.197-second median and 31.556-second maximum. The maximum was an older
WhisperKit + GPT-6 Luna session on October 2, not this implementation.

## Delivery and rollback

Changes remain local and uncommitted. The MacBook's normal app was not replaced;
benchmarking used `/Applications/VoiceiQ-Nemotron-Verification.app`.
No public release or deployment was made. Turn local transcription off to use
the existing cloud path, or select Parakeet to retain local file transcription.
The Mac mini's original local-off, real-time-off preferences were restored.
Cleanup comparison still requires interactive MacBook Keychain authorization.

## Follow-up installation and cleanup results

The user ran the probe interactively on the MacBook. Both cleanup calls succeeded
with Gemini 3.8 Flash and 100 dictionary entries. Parakeet cleanup took 2.707
seconds; Nemotron cleanup took 3.107 seconds. These are single runs without the
original screenshot context, not repeated end-to-end measurements. Both outputs
still used "packet" instead of Parakeet; Nemotron also retained "Nemotrone".

Replaced `/Applications/VoiceiQ.app` on the MacBook with the verified Nemotron
build. Verified the executable matches the benchmark copy, the nested signature
passes, and the notarization ticket validates. Preserved the previous app under
`~/Library/Application Support/VoiceiQ-app-backups/pre-nemotron-20261009-1655.app`.
Automatic launch was blocked by the GUI driver's pending macOS permission gate.
The final process check found no VoiceiQ process; manual launch remains required.
