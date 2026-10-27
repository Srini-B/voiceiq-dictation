# On-device transcription

Settings → Dictation has a **Transcription** picker: **On device**, the
selected provider (Gemini or OpenAI), and **ElevenLabs** once its key is saved.
On device is offered on Apple Silicon Macs running macOS 14+, and on iPhone
and iPad running iOS/iPadOS 17+. The default is the provider.
`SettingsStore.dictationSource` stores the choice (`dictationSource`); a device
with no stored value reads the old `localTranscriptionEnabled` boolean, so an
earlier on-device choice is kept. `localTranscriptionEnabled` is now a derived
read of that picker. Existing local-transcription preferences survive
the removal of Whistle, but its model and runtime are no longer included.
Each model offers its own languages (`LocalSpeechModel.languages`, a list
of `LocalSpeechLanguage` with a locale code and a name). The selected model's
row in Settings has a Language menu; the other rows show "Languages:
English" or "32 languages". The choice is stored once
(`SettingsStore.localSpeechLanguage`, key `localSpeechLanguage`, a locale
code). `LocalSpeechModel.language(code:)` reads it for the selected model and
falls back to English, so a German choice reads as English under Fluid Speech
Mini and returns when Nemotron is picked again.

- Fluid Speech Mini: English only. It is trained on English (FluidVoice model
  card) and ignores the code.
- Nemotron 3.5: 32 locales, the "transcription-ready" and "broad-coverage"
  tiers of NVIDIA's model card. The card's eight "adaptation-ready" locales
  need fine-tuning and are not offered. `LocalTranscriber` passes the code in
  `LocalSpeechOptions.language`, and `NemotronSession` calls
  `setLanguage(code)` with the forced language prefix.

The English tools (speech detection, dictionary spotting) and English number
formatting (`EnglishText`) run only for an English code. For other languages
the transcript goes to cleanup as decoded; the cleanup prompt keeps the
speaker's language. Cloud transcription keeps its own language handling.

iPhone and iPad offer Fluid Speech Mini only (`LocalSpeechModel.available`).
Nemotron stalled on a physical iPhone when both models were offered in
October 2026, and the iOS app has no live-text surface for its streaming
output. A stored Nemotron selection reads as Fluid Speech Mini there. The iOS
app links FluidAudio and runs inference in-process; it releases models after
each dictation and joins active Core ML calls on cancellation. Core ML can
retain runtime caches there, so returning physical memory to its original
baseline within a fixed time is not guaranteed. Downloads run in the
foreground; keep the iOS app open until complete.

In-process dictation has the same deadlines as the Mac helper
(`TimeoutPolicy.localLoad`, `TimeoutPolicy.localTranscribe`): 120 seconds to
load, then at least 120 seconds or twice the recording duration to transcribe.
Core ML work cannot be cancelled, so past the deadline the session is
abandoned, its models are released once the work ends, and the saved recording
goes to cloud transcription. An on-device meeting has the Mac helper's budget,
`TimeoutPolicy.localMeeting` (at least ten minutes, or three times the audio);
past it the in-process run is abandoned the same way and the meeting goes to
cloud transcription when a key is stored.

## Download and delete

1. Set Transcription to On device.
2. Select **Download** beside **Fluid Speech Mini** (252.7 MB) or, on the
   Mac, **Nemotron 3.5** (664.8 MB).
3. Wait for download and file verification. Progress and Cancel remain available.
4. Select a model row to use it. The checkmark shows the selected model.
5. Use the trash icon and confirm **Delete** to remove a downloaded model,
   even with local transcription on.
6. Optional: select **Download** beside **English tools** (103,865,880 bytes,
   shown as 103.9 MB). This row has no checkmark because it is never selected.
   It adds Fluid Speech Mini dictionary correction. See
   [English speech processing](#english-speech-processing).

The model is not bundled, downloaded automatically, or loaded during download.
Each device owns its download. A cancelled or failed download can be retried.
Keep the app open until downloads complete.
Deleting during a local session cancels local processing before removing files;
the saved recording can still use cloud transcription.

When the model is absent, downloading, being deleted, busy, or fails to load,
dictation uses the cloud source (`SettingsStore.cloudDictationSource`): the
selected provider, or ElevenLabs when the picker was last set to it and the
key is still stored. The cloud real-time preference still
applies when no local session starts and the cloud source is the provider;
ElevenLabs has no live socket. A failed local transcription uploads the
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

The section footer (`LocalModelFooter`, shared by both platforms) depends on
the selected model's state. While it is missing, the footer says cloud
transcription is used until it is downloaded. Once it is on disk, the footer
says the first dictation after a download, a system update or a long break
takes longer while the model is prepared for the device. That is Core ML's
device specialization on first load (see "English speech processing"). The OS
caches the result outside the app and drops it after an OS update and when a
model goes unused for a long time (WhisperKit documents the same eviction);
there is no API to check whether the cache is warm. FluidAudio reports cold
Parakeet encoder loads of 51 to 181 seconds on iPhone (FluidAudio issue
#1022). Warm loads take about a second.

Memory: no platform keeps a model loaded between dictations. Each dictation
loads the selected model when recording starts and releases it after
transcription (`LocalTranscriber.finish` stops the session, which drops
`AsrManager` and the tools). The Mac's helper process then exits after 60
idle seconds; the iOS app releases the model in-process and keeps running
only as long as the voice session holds the mic.

Warm-up (iOS, `ModelWarmer` over `LocalModelWarmup`): loads what a dictation
would load and releases it at once, so Core ML prepares it before a dictation
needs it. It uses the same `LocalSpeechOptions` as a dictation in the
on-device language (`LocalTranscriber.sessionOptions`): the dictionary terms
and, for English, the installed English tools, so the CTC vocabulary model is
prepared too. It claims the English tools store as well as the model's store
while it runs. Nothing stays loaded. It runs:

1. In a background processing task (`io.blue.voiceiq.ios.warm-model`,
   `BGProcessingTaskRequest` with no power or network requirement, earliest
   six hours after it was scheduled). iOS picks the time, usually when the
   phone is idle overnight; it does not have to be charging, and iOS may skip
   a night. The app schedules it at launch, on entering the background and
   after each run. The simulator has no BGTaskScheduler.
2. When the app becomes active on an iOS version it has not warmed on yet
   (`modelWarmedOSVersion`), because an update always drops the prepared copy
   whenever it was installed. This also covers the first open after a
   download.

A dictation that starts during a warm-up takes the model's claim from it
(`yieldToDictation`) and loads after the warm-up's load ends, so two Neural
Engine compiles never overlap; the second load is then fast. A warm-up whose
load fails logs "model warm-up failed after Ns" and does not count as having
warmed the iOS version.

Compute units for a dictation (`DictationCompute.encoderUnits`, both
platforms): the Parakeet encoder and the English tools CTC encoder load with
`.cpuOnly`; the decoder and joint keep FluidAudio's default
`.cpuAndNeuralEngine`. The Neural Engine's prepared encoder program is held by
the ANE driver, not by the `e5bundlecache` on disk (a byte-identical restore
of that cache still loads cold), and on iOS it is dropped after hours of idle,
so every first dictation after idle paid a 13 s (M2) to 60 s (iPhone)
compile per encoder. On the CPU the two encoders load in 3 s and 2 s cold
(M2) and in 0.2 s warm, and decode 10 s of audio in 0.24 s against 0.08 s on
the ANE, with the same words. The load log ends with `encoder=cpu`.
`ParakeetVocabulary.loadModels` builds `CtcModels` from the pack's files
itself because `CtcModels.loadDirect` pins the ANE. Meetings
(`LocalMeetingJob`) and Nemotron keep the ANE.

Cold load during a dictation (both platforms): the load starts with the
recording. If it is still running `TimeoutPolicy.localColdLoad` (5 s) after
the recording ends and the selected provider has a key
(`KeychainStore.hasModelKey`, passed as `LocalTranscriber`'s
`cloudOnColdLoad`), the dictation goes to the cloud provider from the saved
audio, and the load goes on as a warm-up (`LocalModelWarmup.adopt`): the
dictation keeps its claims on the model and English tools stores until the
load ends, then the session is stopped and released. The next dictation waits
for that load (`finished(before:)`) and then loads fast. If that next
dictation is also sent to the cloud while still waiting, its load queues
behind the running one (`pending`) and becomes the warm-up when it ends;
loads never overlap and an adopted load never waits for itself. On iOS, under "Never" and
when a warm window runs out during such a load, the voice session keeps the
mic open until the load ends ("session held open for the model load"), so iOS
does not suspend the app with the load half done; the hold ends after
`localLoad` (120 s) at the latest ("model load still running after 120s;
session ended"), so a stalled load cannot keep the mic open. Without a provider key the
dictation waits for the load as before (up to `localLoad`). On the Mac a cold
load takes about 5 s (M2, CPU encoders), so the rule only triggers for a
recording of a second or two after the Core ML cache was cleared.

Load timing in the session log (iOS). Each dictation's load, which overlaps
the recording, is logged as "Fluid Speech Mini loaded in Ns (process up Ns,
prepared models: …)" through `LocalTranscriber.onLoadEvent`; a load longer
than the recording is the wait the user sees in "processing"; a load the
session reports as failed logs "Fluid Speech Mini failed to load after Ns
(…)" instead. A dictation sent to the cloud during a cold load logs "Fluid Speech Mini still loading 5s
after the recording; sent to the cloud, load goes on". A warm-up logs
"model warmed in Ns (reason, process up Ns, before: prepared models: …,
after: prepared models: …)". "process up" is the age of the app process;
"prepared models" (`PreparedModelCache`) counts Core ML's prepared bundles
under `Library/Caches/<bundle id>/com.apple.e5rt.e5bundlecache/`, with their
size and the age of the newest file. Together they tell a slow load apart: the
prepared copies are gone (iOS cleared the cache), or they are present and the
time is spent elsewhere, such as the first Neural Engine load in a new
process.

Stage split in the session log (iOS). After "processed in Ns", the app logs
where that time went, from `DictationCoordinator.onStageTimes`
(`StageTimes`): "finalize 0.4s, decode 5.1s, cleanup 2.8s, insert 0.3s" for
an on-device dictation. "finalize" is the time from key-up to the end of the
audio: trailing speech kept while the user was still talking, then the
microphone teardown. "decode" is `LocalTranscriber.finish`, counted from the
end of the audio, so it includes any wait for a model still loading;
"cleanup" is the writing-rules request; "insert" is typing the result,
omitted when it went to the answer card instead. A cloud socket that
streamed during the recording (`DictationStreaming.runsOnDevice` false)
logs "cloud live final Ns" in place of "decode". A recording uploaded after
the fact, including a cloud fallback after a slow on-device load, logs
"cloud transcribe+cleanup Ns" because one request does both.

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
exactly as with real-time off, including dictionary rescoring when English
tools are installed. A failed preview decode keeps the last text and does not affect the
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
| Fluid Speech Mini | Not loaded | CTC rescoring up to five minutes, needs the pack |
| Nemotron real-time | Logs speech start and end only | None |
| Nemotron file | Trims silent edges up to five minutes | None |

Fluid Speech Mini decodes the recording as captured and does not load the
speech detector. Replaying 15 dictations with the pack showed that edge
trimming changed only two of them, and both lost accuracy (the tail cut moved
words and casing mid-sentence); none improved. It also added about 0.5 s per
dictation. Nemotron file mode keeps trimming. There, speech detection never
splits a recording or removes audio between words. It trims an edge only when
more than 2 seconds of silence precede the first or follow the last detected
speech, and it keeps 1 second of margin. A recording with no detected speech
is decoded in full. If detection fails, the untrimmed audio is used.

With a non-empty Dictionary, the CTC pass adds about 0.3 to 0.5 s per
dictation plus about 0.02 s per second of audio, after a one-time Core ML
compile on first load (about 15 s on an M2 Mac mini). The Fluid Speech Mini
decoder and the CTC spotter see the same samples, so their timings share one
clock.

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

**Meeting transcription** (Settings → Dictation; **Notes transcription** on
iPhone and iPad) is a separate picker from dictation, with the same three
segments (`SettingsStore.meetingSource`, key `meetingSource`, read from the old
`localMeetingTranscriptionEnabled` boolean when absent). On device is a
separate choice from on-device dictation. On the Mac it needs two downloads:
Fluid Speech Mini for the words and **Nemotron 3 Diarization** (199 MB) for
who spoke when. This is the FluidMeet recipe: one ASR model and one diarizer,
joined by time. While the switch is on, the Fluid Speech Mini row stays
offered even with dictation on the cloud, and the diarizer row appears under
the picker. Until both are `.ready`, meetings use the cloud path and the
footer says so. The cloud path is the ElevenLabs route when the picker was
last set to ElevenLabs and its key is stored, otherwise the providers with
keys (`SettingsStore.meetingSpeechRoutes`).

iPhone and iPad need Fluid Speech Mini only (`LocalMeetingTranscriber.diarizes`
is false there). They record the microphone only, so there is no second track
to tell speakers apart by, and the whole transcript is labelled Speaker 1. No
diarizer row is shown, `LocalMeetingRequest.diarizerDirectory` is nil, and
`LocalMeetingJob.run` returns no segments. The footer names Fluid Speech Mini
alone.

The flow, in `MeetingEngine.transcribe(folder:config:)`:

1. `LocalMeetingTranscriber.acquire(runner:)` returns nil unless the setting is
   on and the needed stores are `.ready`. It then takes a session on them. A
   dictation holding Fluid Speech Mini wins: the meeting polls every 2 s for up
   to 600 s, then fails with "busy". While the meeting holds the sessions, a
   dictation falls back to the cloud as it does during a download.
2. `transcribe(folder:)` mixes mic and system onto one timeline with
   `CallAudio.samples` (silence kept, so model seconds are meeting seconds),
   writes it as `local-mix.caf` (Int16 16 kHz mono, a minute at a time), and
   hands a `LocalMeetingRequest` to the runner. The file is removed after.
3. The runner (`LocalMeetingJob.run`) loads Fluid Speech Mini, runs
   `AsrManager.transcribeDiskBacked`, groups token timings into words at
   leading-space boundaries, frees the ASR, then (Mac only) loads the diarizer
   with `Nemotron3Config.offline`, streams the file through it in 60 s chunks,
   and turns the speaker probabilities into `Segment(speaker:start:end)` with
   `Nemotron3Diarizer.segments`. On macOS the runner is
   `LocalMeetingHelper.run`, which spawns its own copy of the speech helper
   (so a dictation's helper is never blocked), kills it on cancel, and times
   out at `max(600 s, 3 × duration)`. On iOS it is
   `LocalSpeechInference.transcribeMeeting`, in process.
4. Words and segments are cached as `local-words-v2.json` beside the audio, so
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
