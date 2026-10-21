# On-device transcription

Settings → Dictation offers **On-device transcription** on Apple
Silicon Macs running macOS 14+, and on iPhone and iPad running iOS/iPadOS 17+.
The toggle is off by default. Existing local-transcription preferences survive
the removal of Whistle, but its model and runtime are no longer included.
On-device dictation is English only: Fluid Speech Mini decodes as English and Nemotron
is locked to `en-US`. Cloud transcription keeps its own language handling.

iPhone and iPad offer Fluid Speech Mini only (`LocalSpeechModel.available`).
Nemotron stalled on a physical iPhone when both models were offered in
October 2026, and the iOS app has no live-text surface for its streaming
output. A stored Nemotron selection reads as Fluid Speech Mini there. The iOS
app links FluidAudio and runs inference in-process; it releases models after
each dictation and joins active Core ML calls on cancellation. Core ML can
retain runtime caches there, so returning physical memory to its original
baseline within a fixed time is not guaranteed. Downloads run in the
foreground; keep the iOS app open until complete.

## Download and delete

1. Turn on local transcription.
2. Select **Download** beside **Fluid Speech Mini** or **Nemotron 3.5**.
   Fluid Speech Mini downloads 252.7 MB; Nemotron downloads 664.8 MB.
3. Wait for download and file verification. Progress and Cancel remain available.
4. Select a model row to use it. The checkmark shows the selected model.
5. Use the trash icon and confirm **Delete** to remove a downloaded model,
   even with local transcription on.
6. Optional: select **Download** beside **English tools** (103,865,880 bytes,
   shown as 103.9 MB). This row has no checkmark because it is never selected.
   It adds speech detection and Fluid Speech Mini dictionary correction. See
   [English speech processing](#english-speech-processing).

The model is not bundled, downloaded automatically, or loaded during download.
Each device owns its download. A cancelled or failed download can be retried.
Keep the app open until downloads complete.
Deleting during a local session cancels local processing before removing files;
the saved recording can still use cloud transcription.

When the model is absent, downloading, being deleted, busy, or fails to load,
dictation uses the selected cloud provider. The cloud real-time preference still
applies when no local session starts. A failed local transcription uploads the
saved recording through the batch cloud path. This is not an offline-only mode.
Dictation, Ask Anything, Translate and macOS Agent all use this selection
logic. Meetings have their own switch; see [On-device meetings](#on-device-meetings).

## Model and real-time selection

Changing the selected model to Nemotron enables **Real-time transcription**.
Turning real-time off afterwards stays off, including across app restarts.
Download completion does not change that preference. Both models can stay on
disk; selecting its row chooses which one dictation uses. Each downloaded model
has its own trash icon, including the model that is not selected.

| Selected, downloaded model | Real-time on | Real-time off |
|---|---|---|
| Fluid Speech Mini | Mac: live preview while speaking, then transcribe the saved recording after stop. iPhone and iPad: transcribe the saved recording after stop | Transcribe the saved recording after stop |
| Nemotron 3.5 | Process PCM while speaking, then finalize after stop | Process the saved recording after stop |
| Selected model missing | Cloud real-time, if available | Cloud file transcription |

Nemotron supports saved audio, so disabling real-time does not require a
different local model. There is no automatic switch to another downloaded model.

### Fluid Speech Mini live preview

Fluid Speech Mini is an offline decoder with no streaming state, so its
preview is display-only text from re-decoding the open tail of the recording
(`ParakeetPreview`). The pump hands the session about one second of PCM at a
time (`PCMRing.bytesPerSecond`); each call decodes the whole tail with a fresh
decoder state and shows the result. Once the tail reaches 12 s the preview
commits a prefix and drops the audio under it, so every decode stays under
the model's 15 s input (`ASRConstants.maxModelSamples`). The cut lands in a
pause: the quietest 150 ms window inside the last 6 s before the 1 s holdback,
so the next decode never starts inside a word. Token times are encoder-frame
emissions, not acoustic edges, and run up to two frames ahead of the audio, so
a word emitted up to 200 ms after the cut is committed too; if the kept audio
decodes it again, `ParakeetPreview.dropOverlap` hides up to three repeated
words (compared without case or punctuation). The final transcript never comes
from the preview: after stop, the session decodes the complete saved recording
exactly as with real-time off, including VAD trimming and dictionary
rescoring. A failed preview decode keeps the last text and does not affect the
final transcript. Dropped PCM only affects the preview. A missing model ends
the preview; the final decode still returns nil and cloud transcription takes
over as before.

The preview runs only where the app shows live text, the Mac pill
(`LocalTranscriber.previews`). On iPhone and iPad the real-time toggle does not
change Fluid Speech Mini behaviour; it still selects cloud real-time
transcription when no local session starts.

## Model lifecycle

Model loading starts only when dictation starts, on a worker rather than the UI
thread. Audio capture writes the existing 16 kHz mono CAF immediately. After
capture drains and closes, Fluid Speech Mini transcribes that complete recording.
Recordings up to five minutes use in-memory audio processing. Longer Fluid Speech Mini
recordings use FluidAudio's disk-backed chunking and skip VAD trimming and
CTC dictionary correction to bound audio memory.
We do not use its sliding-window API because that API can return partial text
after an individual window fails without exposing the failure to its caller.

Nemotron uses the full-vocabulary multilingual Core ML conversion at the
recommended 2240 ms tier. Real-time capture uses a bounded 30-second PCM queue
and coalesces 2.24-second blocks. Missing, dropped or rejected bytes disqualify
the local result and fall back to the saved recording. With real-time off,
Nemotron processes recordings up to five minutes in memory. Longer recordings
use bounded 35,840-frame reads with no VAD trim.
Nemotron real-time never holds the complete recording in a second audio buffer.

At stop, Nemotron receives one silent decoder chunk before finalization, including
when the recording ends on an exact chunk boundary. This gives the decoder
lookahead to emit trailing words. The silence is not written to the recording
and does not count toward captured-frame validation.

If the first chunk contains sustained audio energy but no early word emissions,
Nemotron can re-decode only the first 6.72 seconds of the audio the decoder
received (after any trimming) using its detected language.
When no language tag was emitted, the retry keeps automatic language selection
and adds one leading silent chunk. Recovery prepends at most three opening words
only when the following five words match the primary transcript. It never
replaces the primary suffix. A failed optional retry retains the primary result;
cancellation still cancels transcription. This reduces observed boundary omissions,
but does not guarantee recognition of every word or recover speech before capture.

On Mac, real-time Nemotron, real-time Fluid Speech Mini and cloud transcription
show provisional words in the pill while recording. The latest words stay
visible in a single line. Nemotron updates after each 2.24-second audio block
and Fluid Speech Mini after each second, once the model has loaded. Nemotron
file mode and Fluid Speech Mini with real-time off do not produce live words.
The preview clears on stop, cancel or streaming failure. It never enters History, cleanup or insertion;
those paths use only the validated final transcript.

All app-held model and English tools references are released immediately after
local transcription, before cloud cleanup runs, and on cancellation. There is no
warm model cache; every dictation loads the selected model and any tools again.

On macOS, the signed `VoiceiQLocalSpeech.app` helper owns Core ML inference.
The main app sends model/audio paths, the final frame count, the English tools
folder when installed, and up to 256 dictionary terms over private
length-prefixed pipes, plus PCM blocks for Nemotron streaming. It does not send
API keys, screenshots, or writing prompts.
The helper releases the model and tools before returning the transcript, then
exits after 60 idle seconds to reclaim its remaining process memory. Another
dictation within that minute reuses the process but loads the model again. The
idle timer does not run during recording or recognition. Cancellation or model deletion kills the active
helper and waits for exit before removing files. Helper failure falls back to the
saved-audio cloud path. Startup has a 120-second deadline; recognition allows at
least 120 seconds or twice the recording duration, whichever is longer.

Successful local calls record `fluid-speech-mini-local` (`parakeet-v3-local` before
2026-10-14) or
`nemotron-3.5-multilingual-local`, stage `transcribe`, with zero
provider cost. Cold startup and
final inference still take time; this does not guarantee avoiding "Still working".

Privacy settings show the selected on-device model when it is ready, with the
cloud-failure fallback disclosed. While it is missing or local transcription is
off, the Audio row names the selected cloud provider. This does not change the
cloud routing of cleanup or meetings.

## English speech processing

Local dictation always produces two texts: the **original** decoder transcript
and a **normalized** candidate. Normalization is inverse text normalization
from FluidAudio's `TextNormalizer`, backed by the `NemoTextProcessing` package
trait (NVIDIA NeMo grammars compiled as weighted finite-state transducers). It
turns spoken forms into written forms, such as "five dollars" into "$5". It
runs on final transcripts only, never on the live preview, and needs no
download. It contains no neural weights. If it returns nothing, the candidate
equals its input.

The optional **English tools** pack adds two small Core ML models. The pack
is never required: without it, or when one part fails to load or run, that part
is skipped and the base model still transcribes. Both decoders receive the
recorded audio as captured; there is no noise reduction step. Pack v1 carried
LocalVQE noise reduction, which raised word error rate for both decoders on
replayed dictations and was removed (see
`activities/2026-10-10-drop-speech-enhancement-and-nemotron-bias.md`).

| Folder | Model | Used for |
|---|---|---|
| `vad` | Silero VAD unified 256 ms v6.2.1, threshold 0.4 | Speech detection |
| `ctc` | Parakeet CTC 110M with its tokenizer | Dictionary correction for Fluid Speech Mini |

How each mode uses the pack:

| Mode | Speech detection | Dictionary |
|---|---|---|
| Fluid Speech Mini | Trims silent edges up to five minutes | CTC rescoring up to five minutes, needs the pack |
| Nemotron real-time | Logs speech start and end only | None |
| Nemotron file | Trims silent edges up to five minutes | None |

Speech detection never splits a recording or removes audio between words. It
trims an edge only when more than 2 seconds of silence precede the first or
follow the last detected speech, and it keeps 1 second of margin. A recording
with no detected speech is decoded in full. If detection fails, the untrimmed
audio is used. The Fluid Speech Mini decoder and the CTC spotter see the same samples,
so their timings share one clock.

Nemotron does not receive dictionary terms. FluidAudio's decode-time hotword
bias is a greedy boost with no recovery: a short term such as "Cal" turned a
spoken hesitation into a run of "Ca Ca Ca", and the bias raised word error
rate on replayed dictations. Dictionary terms still reach the cleanup prompt
and the deterministic replacement layer.

Dictionary terms for Fluid Speech Mini come from the first 256 entries in the
Dictionary. A term's misspelling, if set, becomes its alias. Before the
decoder sees them, terms are whitespace-collapsed, deduplicated without regard
to case, limited to 64 characters, and limited to 8 aliases each.
Rescoring requires 0.75
text similarity and an acoustic score better than the original without an
additive vocabulary bonus. Its permissive acoustic rescue pass is disabled
because replay exposed unspoken dictionary insertions. The normalized candidate
uses accepted corrections; the original transcript keeps the decoder's words.

The tools pack is used only when it is ready when dictation starts. The session
then holds the pack like a model, so deleting it cancels local processing and
the saved recording falls back to cloud transcription. Fluid Speech Mini logs its token
confidence for diagnostics. The value is uncalibrated and changes no decision.

## Cleanup

The result uses the existing writing, translation, answer, or Agent path. Cleanup
receives text instructions, transcript, dictionary/context and optional JPEG
screenshots. It never receives audio. Cloud transcription fallback does.
The selected cloud provider and API key remain unchanged.

A local result passes both texts on. History's raw transcript is the original.
Writing rules receive `RAW` plus a `NORMALIZED CANDIDATE` marked as evidence,
not instructions. The prompts ask the model to compare both in context, to fix
a similar-sounding mistake only when one reading clearly fits, and never to
invent names, numbers, AM or PM, or a month. Ask Anything and Translate receive
the original as the instruction or transcript, with the candidate as evidence.
Agent receives the candidate, after dictionary replacements, as its command,
and the original when they differ. Cloud transcripts have no candidate.
When writing rules are off or skipped for a short dictation, a local result
inserts the original with dictionary replacements. This preserves the raw-text
five-second rule and avoids accepting an ambiguous normalization without the
writing model. Rejected or unavailable cleanup also keeps the original.
Meetings do not use the English tools or this cleanup; their transcript goes
to the writing model for notes as it does from the cloud path.

With **Skip cleanup for dictations of 5 seconds or less** enabled, short ordinary
dictations retain the transcript plus local dictionary replacements. Disable it
to use writing rules for short dictations too. Ask Anything, Translate and
Agent retain their requested actions regardless of duration.

## On-device meetings

**Transcribe meetings on device** (Settings → Dictation, both platforms) is a
separate switch from on-device dictation. It needs two downloads: Fluid Speech
Mini for the words and **Nemotron 3 Diarization** (199 MB) for who spoke when.
While the switch is on, the Fluid Speech Mini row stays offered even with
dictation on the cloud, and the diarizer row appears under the switch. Until
both are `.ready`, meetings use the cloud path and the footer says so. This is
the FluidMeet recipe: one ASR model and one diarizer, joined by time.

The flow, in `MeetingEngine.transcribe(folder:config:)`:

1. `LocalMeetingTranscriber.acquire(runner:)` returns nil unless the setting is
   on and both stores are `.ready`. It then takes a session on both stores. A
   dictation holding Fluid Speech Mini wins: the meeting polls every 2 s for up
   to 600 s, then fails with "busy". While the meeting holds the sessions, a
   dictation falls back to the cloud as it does during a download.
2. `transcribe(folder:)` mixes mic and system onto one timeline with
   `CallAudio.samples` (silence kept, so model seconds are meeting seconds),
   writes it as `local-mix.caf` (Int16 16 kHz mono, a minute at a time), and
   hands a `LocalMeetingRequest` to the runner. The file is removed after.
3. The runner (`LocalMeetingJob.run`) loads Fluid Speech Mini, runs
   `AsrManager.transcribeDiskBacked`, groups token timings into words at
   leading-space boundaries, frees the ASR, then loads the diarizer with
   `Nemotron3Config.offline`, streams the file through it in 60 s chunks, and
   turns the speaker probabilities into `Segment(speaker:start:end)` with
   `Nemotron3Diarizer.segments`. On macOS the runner is
   `LocalMeetingHelper.run`, which spawns its own copy of the speech helper
   (so a dictation's helper is never blocked), kills it on cancel, and times
   out at `max(600 s, 3 × duration)`. On iOS it is
   `LocalSpeechInference.transcribeMeeting`, in process.
4. Words and segments are cached as `local-words-v1.json` beside the audio, so
   a Retry after the notes fail does not decode twice. Each word takes the
   speaker active at its midpoint, else the one overlapping it most, else the
   nearest within 2 s, else the previous word's. Speakers are renumbered in
   order of first appearance; the owner is marked from the mic track with
   `MeetingTranscriber.markOwner` as on the cloud path. Turns come from
   `SpeakerLinker.overlappingTurns`.
5. The transcript is saved, then notes are written by the cloud writing model.
   With no key the meeting is marked failed with "add a key for notes, then
   Retry"; the transcript is kept and Retry reuses the cache.

If the on-device pass fails and a key is stored, the cloud path runs. A
cancelled job does not fall back. Usage is recorded under the Fluid Speech
Mini model ID with zero cost.

## Dependencies and storage

FluidAudio is pinned to 0.17.7. Fluid Speech Mini by FluidVoice
([post](https://fluidvoice.com/labs/fluid-speech-mini)), an English fine-tune of
Parakeet TDT 0.6B v3, comes from `FluidVoice-Labs/fluid-speech-mini-coreml`,
revision `d81c3160dfe5a5e1f8f7267164a07d30617a3a1a`. The 21 paths, byte sizes
and SHA-256 digests, totalling 252,710,832 bytes, are in
`ParakeetManifest.swift`. It has the Parakeet v3 Core ML contract, so FluidAudio
loads it as `.v3`. FluidAudio 0.17.7 looks for the v3 joint at
`JointDecisionv3.mlmodelc`, so the repository's `JointDecision.mlmodelc`
installs under that name. That joint has no top-K outputs, which turns off only
FluidAudio's English script filter. The install folder stays
`Models/parakeet-v3`, so the first launch after the change removes an earlier
Parakeet v3 download (483.1 MB) and the row shows Download again.
Downloads verify every file in a staging
folder, then atomically publish a revision marker. Startup checks marker and file
sizes. No FluidAudio auto-download API is called.

Nemotron comes from
`FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML`, revision
`1a41b75758b0337ff67db7d5408280aaaf23074e`, folder `multilingual/2240ms/`.
`NemotronManifest.swift` pins its 22 files and SHA-256 digests, totalling
664,846,846 bytes. The same verification and atomic installation apply.

Nemotron 3 Diarization comes from `FluidInference/nemotron-3-diarization-coreml`,
revision `25a90f97f254428d4b30374b76af9c74fdee8327`: the offline monolithic v2
bundle under `monolithic/v2/` plus `learnable_sil_emb.bin` at the repository
root, installed flat as `Models/nemotron-3-diarization-offline/<revision>`,
the layout `Nemotron3Models.load(config: .offline, directory:)` reads.
`NemotronDiarizerManifest.swift` pins its 5 files, totalling 199,162,403 bytes.

English tools come from two Hugging Face repositories, each pinned to one
commit. `EnglishToolsManifest.swift` pins all 17 files, sizes and SHA-256
digests, totalling 103,865,880 bytes, and installs them as one verified pack
at `Models/english-tools/v2/{vad,ctc}`. Bump the pack revision when any
pinned file changes so the old pack fails its marker check and is cleared.
A v1 pack is cleared at the next launch and the row shows Download again.

| Folder | Repository | Revision | Bytes |
|---|---|---|---:|
| `vad` | `FluidInference/silero-vad-coreml` | `b419383c55c110e2c9271fa6ee0ea83d03c70d96` | 1,063,425 |
| `ctc` | `FluidInference/parakeet-ctc-110m-coreml` | `accdafd8cf8a2ff1cabe3c11e54416b405d409aa` | 102,802,455 |

FluidAudio's `NemoTextProcessing` trait is enabled for inverse text
normalization. It links the prebuilt `text-processing-rs` v0.3.1 static library,
which contains compiled grammars and no model weights. Only the inference
binaries link it: the Mac speech helper and the iOS app. The Mac UI does not.

Storage is `Application Support/VoiceiQ/Models/<model>/<revision>`.
Neither the keyboard nor Live Activity extension links FluidAudio. Models load
in the macOS helper or the iOS host app. See `THIRD_PARTY_NOTICES.md` for SDK
and model attribution.
