# On-device transcription

Settings → Dictation has a **Transcription** picker: **On device** and the
selected provider (Gemini or OpenAI).
On device is offered on Apple Silicon Macs running macOS 14+, and on iPhone
and iPad running iOS/iPadOS 17+. The default is the provider.
`SettingsStore.dictationSource` stores the choice (`dictationSource`); a device
with no stored value reads the old `localTranscriptionEnabled` boolean, so an
earlier on-device choice is kept. A stored choice this build no longer offers
reads as the provider. `localTranscriptionEnabled` is now a derived
read of that picker. Existing local-transcription preferences survive
the removal of Whistle, but its model and runtime are no longer included.
Each model offers its own languages (`LocalSpeechModel.languages`, a list
of `LocalSpeechLanguage` with a locale code and a name). The selected model's
row in Settings has a Language menu; the other rows show "Languages:
English" or "25 languages". The choice is stored once
(`SettingsStore.localSpeechLanguage`, key `localSpeechLanguage`, a locale
code). `LocalSpeechModel.language(code:)` reads it for the selected model and
falls back to English, so a German choice reads as English under Fluid Speech
Mini and returns when Fluid Speech Pro is picked again.

- Fluid Speech Mini: English only. It is trained on English (FluidVoice model
  card).
- Fluid Speech Pro (macOS 15 and iOS 18 or later): the 25 European languages of Parakeet TDT 0.6B
  v3. The decoder detects the language itself. `ParakeetSession` passes no
  `language` to FluidAudio: that argument only filters the joint's top-K
  tokens by script, and with French it turned "ce soir" into "ce sort".

Neither model is told the language. The English tools (dictionary spotting)
and English number formatting (`EnglishText`) run only for an English code. For other languages
the transcript goes to cleanup as decoded; the cleanup prompt keeps the
speaker's language. Cloud transcription keeps its own language handling.

Fluid Speech Pro's Core ML build targets macOS 15 and iOS 18, so older systems
offer Fluid Speech Mini only (`LocalSpeechModel.available`). A stored Fluid
Speech Pro selection reads as Fluid Speech Mini there. On iPhone and iPad Pro
loads like Mini: in-process through `LocalSpeechInference.makeSession`
(`ParakeetSession`, CPU encoder), released after each dictation, and warmed by
`ModelWarmer`, which warms again when the iOS version or the selected model
changes. Its 16-bit encoder weighs 1.19 GB, about five times Mini's palettized
one, so it needs that much more memory while it is loaded.

Claude's cloud transcription is DeepInfra's Nemotron 3.5 Transcribe, which
needs the optional DeepInfra key. The pickers always offer On device and
Nemotron 3.5. With Nemotron 3.5 picked and no DeepInfra key
(`SettingsStore.providerTranscribes` is false), a row under the picker says
where to add the key, and a dictation that cannot be transcribed on device
fails with `.auth` instead of sending audio anywhere
(`GeminiClient.deepInfraTranscription`).

### Live transcription with Nemotron 3.5 Transcribe (Mac)

DeepInfra serves Nemotron 3.5 Transcribe for whole files only, with no
WebSocket, and returns no word timings for it (`verbose_json` with
`timestamp_granularities[]=word` came back as text and duration only,
2026-11-02). With **Real-time transcription** turned on by the user, the
DeepInfra key saved and a dictation going to Nemotron 3.5, the Mac sends the
recording in pieces while
it is made (`DeepInfraLiveTranscriber`, chosen in
`LiveTranscriber.makeCloudFromSettings`), and those pieces are the transcript.
It is off by default: until the toggle is changed, `liveTranscriptionEnabled`
reads off for Claude with Nemotron 3.5 picked (on for every other setup), and
the live path also checks `liveTranscriptionChosen` so an on-device dictation
that falls back to Nemotron 3.5 does not start it either.


- After each second of new audio, and never with two requests in flight, the
  open tail of the recording goes to `/audio/transcriptions` as 16 kHz WAV
  with the dictionary as `prompt`. The pill shows the locked-in text plus the
  latest tail text.
- Once the tail reaches 12 s, the next request is a commit. It finds the
  longest quiet run of 10 ms blocks in the 6 s before the last second (quiet
  is up to 3x the quietest block's RMS and never above about -45 dBFS), sends
  only the audio up to 100 ms into that run, locks the returned text in, and
  drops the tail up to 100 ms before the run ends. With no run that quiet,
  such as speech over steady noise, it cuts in the quietest 10 ms and drops
  nothing. No audio is heard twice, so no words repeat across a
  cut. Each piece keeps at most 100 ms of the pause.
- Nemotron sometimes writes a dictionary word from the `prompt` into the short
  silence at a piece's edge ("waveform. VoiceiQ Third, we…"); whole-recording
  uploads never did. `Window.withoutLeakedTerms` drops a single-word
  dictionary term at a piece's start (running straight into a capitalized
  word) or end (after a sentence end, with no punctuation of its own) only
  when an earlier preview heard that same audio with more context and did
  not contain the term. A preview counts for a piece's start only if it heard
  at least a second past the cut, and for its end only if it heard the whole
  piece. Without that evidence the word is kept.
- On stop, a request in flight is cancelled and only the remaining tail is
  sent. The transcript is the locked-in text plus that last piece, and goes
  to Claude cleanup like any live transcript (`StageTimes.Source.cloudLive`).
- The saved recording is uploaded instead, as with real-time off, when three
  requests in a row fail, the last piece fails, or the bytes received do not
  match the frames written to the recording.

Nemotron does not hear across a cut, so punctuation at a cut can differ from
one whole upload; cleanup usually evens it out. Each request bills its audio,
so a dictation bills about three to four times its length (measured 81 s
billed for 22 s and 156 s for 50 s). The requests are booked as **Live
transcription** under the dictation (the coordinator creates the streamer
inside the dictation's `UsageMeter.scope`). DeepInfra answers a request in
about 2 to 3 s whatever its length (up to 5 s seen), so the gain after stop is
small: stop to transcript took 2.4 s against 3.3 s for one upload of a 22 s
dictation, and 2.7 s against 4.1 s for 50 s. iPhone and iPad still upload the
saved recording after stop.

Fluid Speech Pro replaced the on-device Nemotron 3.5 ASR Streaming model on
2026-11-02. A stored `nemotron` selection reads as Fluid Speech Pro
(`LocalSpeechModel(stored:)`); until Pro is downloaded, dictation uses the
cloud provider. The first time the Pro store is opened, it deletes the old
`Models/nemotron-3.5-multilingual-2240ms` folder (`LocalModelManifest.replaces`).

The iOS app links FluidAudio and runs inference in-process; it releases models after
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
2. Select **Download** beside **Fluid Speech Mini** (252.7 MB) or, on
   macOS 15 or iOS 18 and later, **Fluid Speech Pro** (1.23 GB).
3. Wait for download and file verification. Progress and Cancel remain available.
4. Select a model row to use it. The checkmark shows the selected model.
5. Use the trash icon and confirm **Delete** to remove a downloaded model,
   even with local transcription on.
6. Optional: select **Download** beside **English tools** (103,865,880 bytes,
   shown as 103.9 MB). This row has no checkmark because it is never selected.
   It adds dictionary correction for English dictation. See
   [English speech processing](#english-speech-processing).

The model is not bundled, downloaded automatically, or loaded during download.
Each device owns its download. A cancelled or failed download can be retried.
Keep the app open until downloads complete.
Deleting during a local session cancels local processing before removing files;
the saved recording can still use cloud transcription.

When the model is absent, downloading, being deleted, busy, or fails to load,
dictation uses the selected provider. The cloud real-time preference still
applies when no local session starts. A failed local transcription uploads the
saved recording through the batch cloud path. This is not an offline-only mode.
Dictation, Ask Anything, Translate and macOS Agent all use this selection
logic. Meetings have their own switch; see [On-device meetings](#on-device-meetings).

## Model and real-time selection

Changing the selected model does not change **Real-time transcription**.
Download completion does not change it either. Both models can stay on
disk; selecting its row chooses which one dictation uses. Each downloaded model
has its own trash icon, including the model that is not selected.

| Selected, downloaded model | Real-time on | Real-time off |
|---|---|---|
| Fluid Speech Mini | Mac: live preview while speaking, then transcribe the saved recording after stop. iPhone and iPad: transcribe the saved recording after stop | Transcribe the saved recording after stop |
| Fluid Speech Pro | Mac: live preview while speaking, then transcribe the saved recording after stop. iPhone and iPad: transcribe the saved recording after stop | Transcribe the saved recording after stop |
| Selected model missing | Cloud real-time, if available | Cloud file transcription |

Both models decode whole recordings; the live preview re-decodes the open
tail of the recording (`ParakeetPreview`). There is no automatic switch to
another downloaded model.

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
(`LocalMeetingJob`) keep the ANE. Fluid Speech Pro's 16-bit encoder runs on
the CPU either way: Core ML places all 1,393 of its ops on the CPU even when
the ANE is allowed, while Mini's palettized encoder gets 1,681 ANE ops.

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

### Live preview (Fluid Speech Mini and Pro)

Both models are offline decoders with no streaming state, so the
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
capture drains and closes, the selected model transcribes that complete recording.
Recordings up to five minutes use in-memory audio processing. Longer
recordings use FluidAudio's disk-backed chunking and skip CTC dictionary
correction to bound audio memory.
We do not use its sliding-window API because that API can return partial text
after an individual window fails without exposing the failure to its caller.

On Mac, real-time on-device and cloud transcription show provisional words in
the pill while recording. The latest words stay visible in a single line. Both
on-device models update after each second, once the model has loaded. With
real-time off they do not produce live words.
The preview clears on stop, cancel or streaming failure. It never enters History, cleanup or insertion;
those paths use only the validated final transcript.

All app-held model and English tools references are released immediately after
local transcription, before cloud cleanup runs, and on cancellation. There is no
warm model cache; every dictation loads the selected model and any tools again.

On macOS, the signed `VoiceiQLocalSpeech.app` helper owns Core ML inference.
The main app sends model/audio paths, the final frame count, the English tools
folder when installed, and up to 256 dictionary terms over private
length-prefixed pipes, plus PCM blocks for the live preview. It does not send
API keys, screenshots, or writing prompts.
The helper releases the model and tools before returning the transcript, then
exits after 60 idle seconds to reclaim its remaining process memory. Another
dictation within that minute reuses the process but loads the model again. The
idle timer does not run during recording or recognition. Cancellation or model deletion kills the active
helper and waits for exit before removing files. Helper failure falls back to the
saved-audio cloud path. Startup has a 120-second deadline; recognition allows at
least 120 seconds or twice the recording duration, whichever is longer.

Successful local calls record `fluid-speech-mini-local` (`parakeet-v3-local` before
2026-10-14) or `fluid-speech-pro-local` (`nemotron-3.5-multilingual-local`
before 2026-11-02), stage `transcribe`, with zero
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

The optional **English tools** pack adds two small Core ML models; only the
CTC model is loaded now. The pack is never required: without it, or when it
fails to load or run, the base model still transcribes. Both decoders receive the
recorded audio as captured; there is no noise reduction step. Pack v1 carried
LocalVQE noise reduction, which raised word error rate for both decoders on
replayed dictations and was removed (see
`activities/2026-10-10-drop-speech-enhancement-and-nemotron-bias.md`).

| Folder | Model | Used for |
|---|---|---|
| `vad` | Silero VAD unified 256 ms v6.2.1 | Not loaded; only the retired Nemotron path used it |
| `ctc` | Parakeet CTC 110M with its tokenizer | Dictionary correction for English dictation, up to five minutes |

The `vad` folder stays in the pack because removing it would change the pack
revision and make every install download all 103.9 MB again. Both models
decode the recording as captured. Replaying 15 dictations showed that edge
trimming changed only two of them, and both lost accuracy (the tail cut moved
words and casing mid-sentence); none improved.

With a non-empty Dictionary, the CTC pass adds about 0.3 to 0.5 s per
dictation plus about 0.02 s per second of audio, after a one-time Core ML
compile on first load (about 15 s on an M2 Mac mini). The decoder and the
CTC spotter see the same samples, so their timings share one clock.

FluidAudio's decode-time hotword bias is not used: it is a greedy boost with
no recovery, and with the retired Nemotron model a short term such as "Cal"
turned a spoken hesitation into a run of "Ca Ca Ca". Dictionary terms also
reach the cleanup prompt and the deterministic replacement layer.

Dictionary terms for English dictation come from the first 256 entries in the
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
iPhone and iPad) is a separate picker from dictation, with the same
segments (`SettingsStore.meetingSource`, key `meetingSource`, read from the old
`localMeetingTranscriptionEnabled` boolean when absent). On device is a
separate choice from on-device dictation. On the Mac it needs two downloads:
the selected speech model (Fluid Speech Mini or Pro, the one checked in the
model list) for the words and **Nemotron 3 Diarization** (199 MB) for who
spoke when. This is the FluidMeet recipe: one ASR model and one diarizer,
joined by time. While the switch is on, the model rows stay offered and
selectable even with dictation on the cloud, and the diarizer row appears
under the picker. Until 2026-11-02 meetings always used Fluid Speech Mini,
so a phone with only Pro downloaded sent notes to the cloud. Until both are `.ready`, meetings use the cloud path and the
footer says so. The cloud path is the providers with keys
(`SettingsStore.meetingProviders`).

iPhone and iPad need the selected speech model only (`LocalMeetingTranscriber.diarizes`
is false there). They record the microphone only, so there is no second track
to tell speakers apart by, and the whole transcript is labelled Speaker 1. No
diarizer row is shown, `LocalMeetingRequest.diarizerDirectory` is nil, and
`LocalMeetingJob.run` returns no segments. The footer names the selected
model alone.

The flow, in `MeetingEngine.transcribe(folder:config:)`:

1. `LocalMeetingTranscriber.acquire(runner:)` returns nil unless the setting is
   on and the needed stores are `.ready`. It then takes a session on them. A
   dictation holding the speech model wins: the meeting polls every 2 s for up
   to 600 s, then fails with "busy". While the meeting holds the sessions, a
   dictation falls back to the cloud as it does during a download.
2. `transcribe(folder:)` mixes mic and system onto one timeline with
   `CallAudio.samples` (silence kept, so model seconds are meeting seconds),
   writes it as `local-mix.caf` (Int16 16 kHz mono, a minute at a time), and
   hands a `LocalMeetingRequest` to the runner. The file is removed after.
3. The runner (`LocalMeetingJob.run`) loads the selected speech model, runs
   `AsrManager.transcribeDiskBacked` with no language hint (as dictation), groups token timings into words at
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
   On a call whose echo-cancelled mic passed the echo check
   (`CallAudio.isOnline && micIsEchoFree`), the tracks are not mixed. The mic
   is decoded alone, and every word on it is the owner's
   (`local-words-mic-v1.json`). The system track is decoded and diarized
   alone, and its speakers are everyone else (`local-words-system-v1.json`).
   `LocalMeetingTranscriber.byTrack` joins them by time. A mix keeps only one
   voice where two overlap. On a 2.5-minute Meet call (2026-10-27) it lost a
   far-side "Yeah" said over the owner and gave the owner a far-side
   "this."; decoded alone, each track had every word.
   On the far side, a word where the diarizer heard two people at once goes
   to whichever of them said the nearest word in the same phrase (words
   under 0.3 s apart) that only one person was heard on
   (`LocalMeetingTranscriber.settled`). Other words keep their label, so a
   one-word reply between someone else's words stays a turn of its own.
5. The transcript is saved, then notes are written by the cloud writing model.
   With no key the meeting is marked failed with "add a key for notes, then
   Retry"; the transcript is kept and Retry reuses the cache.

If the on-device pass fails and a key is stored, the cloud path runs. A
cancelled job does not fall back. Usage is recorded under the Fluid Speech
Mini model ID with zero cost.

## Dependencies and storage

FluidAudio is pinned to 0.18.2. Fluid Speech Mini by FluidVoice
([post](https://fluidvoice.com/labs/fluid-speech-mini)), an English fine-tune of
Parakeet TDT 0.6B v3, comes from `FluidVoice-Labs/fluid-speech-mini-coreml`,
revision `d81c3160dfe5a5e1f8f7267164a07d30617a3a1a`. The 21 paths, byte sizes
and SHA-256 digests, totalling 252,710,832 bytes, are in
`ParakeetManifest.swift`. It has the Parakeet v3 Core ML contract, so FluidAudio
loads it as `.v3`. FluidAudio 0.18.2 looks for the v3 joint at
`JointDecisionv3.mlmodelc`, so the repository's `JointDecision.mlmodelc`
installs under that name. That joint has no top-K outputs, which turns off only
FluidAudio's English script filter. The install folder stays
`Models/parakeet-v3`, so the first launch after the change removes an earlier
Parakeet v3 download (483.1 MB) and the row shows Download again.
Downloads verify every file in a staging
folder, then atomically publish a revision marker. Startup checks marker and file
sizes. No FluidAudio auto-download API is called.

Fluid Speech Pro by FluidVoice comes only as a NeMo checkpoint
(`FluidVoice-Labs/fluid-speech-pro`, revision
`53f490b9292c5943847f635b7abfc3f123018964`). It is Parakeet TDT 0.6B v3 with
one extra encoder block (`fv_insert`) after subsampling. VoiceiQ converted it
to 16-bit Core ML with FluidInference's mobius Parakeet v3 converter, with
the block traced into the encoder, and published the package at
`cyron/fluid-speech-pro-coreml`, revision `ec52e16204b3d2c4c8bf60e576728fc58a825689`.
`FluidSpeechProManifest.swift` pins its 21 files and SHA-256 digests, totalling
1,228,362,429 bytes, in Mini's layout (`JointDecisionv3.mlmodelc` included).
Unlike Mini's, its joint has top-K outputs. It installs to
`Models/fluid-speech-pro/<revision>` with the same verification and atomic
installation. Conversion and parity checks against NeMo are recorded in
`activities/2026-11-02-fluid-speech-pro-replaces-nemotron.md`.

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
The `Diarizer` trait is enabled for the meeting diarizer (`Nemotron3Diarizer`).
Listing traits turns FluidAudio's defaults off, so the `TTS` trait and its
resources are not built.

Storage is `Application Support/VoiceiQ/Models/<model>/<revision>`.
Neither the keyboard nor Live Activity extension links FluidAudio. Models load
in the macOS helper or the iOS host app. See `THIRD_PARTY_NOTICES.md` for SDK
and model attribution.
