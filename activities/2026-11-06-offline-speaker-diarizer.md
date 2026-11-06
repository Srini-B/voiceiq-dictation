# 2026-11-06: pyannote community-1 replaces Nemotron 3 Diarization (Mac)

## Why

In meetings, every line should go to the right person. Nemotron 3
Diarization, the on-device diarizer, merged two similar voices (for example
two female voices) into one speaker, so one person's lines went to the
other.

## Measurements

Mac mini M2, FluidAudio 0.18.2 (the version the app pins).

| | Nemotron 3 (`Nemotron3Config.offline`, as the app ran it) | `OfflineDiarizerManager`, community-1 defaults |
|---|---:|---:|
| Speaker confusion, 5 similar-voice files | 12.1 % of speech | 2.1 % (0.0 % with the speaker count given) |
| DER, AMI ES2004a (real meeting) | 25.4 % | 17.3 % |

- Nemotron merged the Samantha and Karen voices into one speaker.
- `OfflineDiarizerManager`: peak footprint about 0.8 GB, real-time factor
  0.0045.

## Decision

- Replace Nemotron 3 with FluidAudio's `OfflineDiarizerManager` (pyannote
  community-1 port: powerset segmentation, WeSpeaker embeddings, PLDA, VBx
  clustering) at its community-1 defaults.
- Not `warmStartFb = 0.4`: it was tuned on the same test files, so its gain
  there says nothing about other meetings.
- No speaker count from the user. The user never types a count, and manual
  speaker tools were rejected. The count is chosen from the audio instead
  (below).

## Implementation

- `SpeakerDiarizerManifest.swift` replaces `NemotronDiarizerManifest.swift`:
  `FluidInference/speaker-diarization-coreml` at
  `df2625ac79a7ac6b65ad868fee6d80f320da4232`, the revision FluidAudio 0.18.2
  pins (`ModelNames.swift`, `Repo.diarizer.revision`), so the app runs the
  files the benchmark ran. 21 files, 21,599,417 bytes (Nemotron:
  199,162,403), CC BY 4.0. Every file was downloaded and checked against the
  tree's LFS SHA-256 or git blob SHA-1. The install folder is
  `Models/speaker-diarization-community-1`, and the old
  `nemotron-3-diarization-offline` folder is removed as a stale item, so an
  old install never counts as the new model.
- `LocalMeetingJob.diarize` loads the five files itself with
  `MLModel(contentsOf:)` and the compute units `OfflineDiarizerModels.load`
  uses (`.all`, FBank `.cpuOnly`), then hands them to
  `OfflineDiarizerManager.initialize(models:)`. FluidAudio's own loader
  checks for a `.fluidaudio-revision` marker that a verified install never
  has, and without it downloads from Hugging Face; `prepareModels` also
  purges the folder and downloads again after a failed load.
- `prepare(audioSource:)` on FluidAudio's disk-backed source converts the mix to a temporary Float32 file and
  memory-maps it, so the audio is never held in memory. What grows with
  length is the per-step segmentation output and embeddings (2 s steps, up
  to 3 local speakers each): tens of MB for two hours, estimated from the
  source, not measured.
- Speaker ids (`S1`, `S2`, ...) become slots in order of first appearance.
  Overlapping speech is kept (community-1's default), which
  `LocalMeetingTranscriber.settled` already handles. A silent track throws
  `noSpeechDetected`; it now gives no segments, as Nemotron did.
- The on-device caches that hold speaker stretches moved to new names
  (`local-words-v3.json`, `local-words-system-v2.json`, `speakers-v2.json`,
  `speakers-system-v2.json`), so a Retry of an older meeting runs the new
  diarizer instead of reusing Nemotron's speakers. The mic-only cache keeps
  its name: it is never diarized.

## Choosing the speaker count

On a notarized build, a 61.5 s Samantha/Karen conversation still came out as
one speaker at the defaults, as with Nemotron; `numSpeakers = 2` split all 9
turns correctly. So the embeddings separate the pair and only the count is
wrong. A second benchmark on the Mac mini (33 files, split into tuning and
held-out halves before any selector ran, frozen by sha256) compared ways to
pick the count:

- **Shipped: step up while the closest voices stay apart.** Run the
  defaults, then re-cluster the same prepared audio with one more speaker at
  a time (at most 3 more, 8 in all). Keep a count while every speaker has at
  least 3 chunk embeddings and the two closest mean voices (L2-normalized
  WeSpeaker embeddings) are at least 0.275 apart in cosine distance; stop at
  the first that fails. It never goes below the defaults.
- Held-out: exact count on 17 of 18, the same as the defaults, trading one
  merge (the app's Samantha/Karen case, DER 42.1% to 9.6%) for one split (a
  LibriSpeech reader recorded in two sessions, DER 3.6% to 15.4%). Tuning
  half: 14 of 15 against 11. Leave-one-out over all 33: 31 exact against 28,
  and the threshold came out at 0.275 in every fold. None of the 8
  single-voice controls split (largest score 0.111).
- Cost: each extra re-cluster is about 1.1 s per hour of audio (RTF
  +0.00034); no model inference is repeated.
- Rejected: Fisher ratio and silhouette selectors (missed the app case or
  did worse), config knobs alone (over-split AMI), and forcing a known count
  (on AMI TS3003a it switches to K-means and doubled DER).
- **Participant count from the call window: not used.** As a cap it is a
  disaster when several people share one device (true count minus 1: exact
  4 of 18 held-out); as permission to look further it changed nothing,
  because no file needed more than 3 extra speakers.
- Known risk: one person whose channel changes mid-meeting (a new
  microphone) can come out as two speakers.

Full report: the "Choosing the speaker count automatically for
OfflineDiarizerManager" artifact in the benchmark thread;
`~/bench/diarize/run_count_selection.sh` on the Mac mini reruns it.

## Not verified

- No Apple build or run in this change's Linux orb. The manifest's hashes
  were checked against the downloaded files; the Swift was not compiled.
