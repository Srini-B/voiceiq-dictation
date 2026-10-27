# First dictation still slow after the overnight warm-up (iPhone)

2026-10-26. Follows `2026-10-22-ios-cold-model-load.md`.

## Report

With the warm-up from 2026-10-22 installed, the first on-device dictation
after an overnight or hour-long idle still takes about a minute to type its
result; later dictations are fast. Fluid Speech Mini with the English tools,
warm window "Never", dictations started from the keyboard in WhatsApp. The
owner asked whether the model is in memory when a dictation starts.

## Findings from the owner's session log

- The model is not in memory between dictations. `LocalTranscriber` starts
  the load when recording starts and `finish()` releases it; the load overlaps
  the recording, so the "processing" wait is load time minus recording
  length. Keeping it resident would not survive the process ending, which is
  what happens after an idle of hours.
- Background warm-ups ran and took a full cold load: 58.8 s (10-24 10:25),
  61.3 s (10-26 08:05). One took 0.4 s (10-25 06:40), which means nothing was
  prepared that time (the task ran, found nothing to do, or the load returned
  early).
- The warm-up did not make the next dictation fast. Two hours after the
  61.3 s warm-up, a 13 s dictation processed for 37.0 s, a load of about 50 s,
  the same as cold. Five minutes later: 3.9 s.
- A previous dictation does make the next one fast. On 10-22, gaps of about
  one hour gave loads of 5 s or less; gaps of 2 h 10 m to 2 h 20 m gave 7 to
  11 s; the first of the day gave 33 s processing.
- So what the warm-up prepares is lost within two hours, while what a
  dictation leaves behind lasts at least an hour and fades over two. The log
  cannot say which of two causes this is: iOS clears Core ML's prepared
  copies under `Library/Caches`, or the slow part is tied to the process (the
  first Neural Engine load in a fresh process) and a suspended process is what
  keeps the next dictation fast. The two need different fixes.
- Gap: the warm-up passed empty `LocalSpeechOptions`, so it never loaded the
  English tools' CTC vocabulary model that a dictation loads when the
  dictionary has terms. Fixed below; it is not the main cost.
- Rejected: `.cpuAndGPU` loads in about a second on the same phone (FluidAudio
  issue #1022) but the GPU is not available to a background app, and our
  dictations run in the background.

## What changed

The owner confirmed the cloud fallback to the selected provider and asked for
the cold load itself to be addressed as well.

- Cold-load fallback: a dictation whose model is still loading 5 s after
  the recording ends goes to the selected cloud provider when its key is
  stored (`TimeoutPolicy.localColdLoad`, `LocalTranscriber.finish`). The
  owner set 5 s; it started at 3 s, which a warm load can still exceed on a
  short recording. The load is not abandoned: `LocalModelWarmup.adopt` keeps
  the stores claimed, stops the session when the load ends, and the next
  dictation waits for it and loads fast. `abort` from the coordinator leaves a
  handed-off load alone. `LiveTranscriber.makeFromSettings` passes
  `KeychainStore.hasModelKey` as `cloudOnColdLoad` on both platforms; the Mac
  gets the same rule because its own cold load is about 15 s (M2, measured
  10-22), which a recording under 10 s does not cover. The Mac was not
  excluded on purpose; it can be by passing `false` under `#if os(macOS)`.
- Voice session: under "Never", or when the warm window runs out, the mic
  stays open while such a load finishes ("session held open for the model
  load"), because a load that iOS suspends half way prepares nothing. The mic
  dot therefore stays about a minute after the first dictation of the day.
- `LocalSpeechSession.load` returns whether the model loaded. The warm-up
  reports "model warm-up failed after Ns" instead of "warmed", and a failed
  warm-up does not mark the iOS version as warmed. The 0.4 s warm-up of 10-25
  would have been reported this way.
- Warm-up loads what a dictation loads: `LocalTranscriber.sessionOptions`
  (dictionary terms, English tools when installed and the language is
  English) is shared by the dictation and `LocalModelWarmup`, which also
  claims and releases the English tools store.
- Session log, per dictation: "Fluid Speech Mini loaded in Ns (process up Ns,
  prepared models: N, size, newest age ago)" and "Fluid Speech Mini still
  loading 5s after the recording; sent to the cloud, load goes on" via
  `LocalTranscriber.onLoadEvent`.
- Session log, per warm-up: the same process age and the prepared-model cache
  before and after the load (`PreparedModelCache`, iOS app).

The next slow first dictation will show whether the prepared bundles are
present, and whether the process is new. That decides the fix:

- Bundles gone: the cache is purged by iOS; a warm-up cannot hold it. Fall
  back to cloud transcription when the model is still loading a few seconds
  after the user stops, and let the load finish so the next dictation is fast.
- Bundles present, process new: the cost is per process. Same cloud fallback,
  or a warm-up timed closer to use (for example on the keyboard's first
  appearance of the day), since the background task runs hours before.

## What Apple, FluidAudio and other apps say about the cold load

Researched 10-26 (sources in the thread; clones under `/tmp/amp-librarian`).

- Apple documents the prepared copy as `Library/Caches/<bundle
  id>/com.apple.e5rt.e5bundlecache/<OS build>/…`, keyed by the compiled
  model's full path, the configuration and the OS version (WWDC23 session
  10049; "Analyzing a Core ML model's performance in Xcode"). It is deleted on
  an OS update, when the system reclaims storage, and when the `.mlmodelc`
  path or content changes, which on iOS includes every app install or update
  because the container UUID changes. Apple states no time-based or idle
  eviction and nothing about a per-process cost.
- WhisperKit's code comment claims the cache is evicted "if the models are not
  used for extended periods of time" (`Configurations.swift` L48–74), with no
  Apple reference. FluidAudio's `Documentation/ASR/Cohere.md` says on macOS a
  fresh process always re-pays the compile regardless of the disk cache; our
  Mac measurement below contradicts that for Parakeet (0.15 s in a new helper
  process after one complete load). `m0at/ANEtransformers` (reverse
  engineered, macOS) describes an in-memory compiled-program cache in the
  `aned` daemon that survives process exits. The owner's "fast for an hour,
  cold after two" fits such a daemon-side cache being dropped under memory
  pressure or time better than the disk cache being purged; unconfirmed.
- Dictus issue #472: a Parakeet v3 compile that takes 17 s in the foreground
  took 270 s backgrounded ("throttled in the background"); its roadmap notes
  the same. Our background warm-up compiles while backgrounded, which may be
  why it takes 53–61 s, and may be why the result does not help later: a
  throttled compile that the task budget cuts off writes nothing.
- FluidAudio issue #1022 (open): the maintainer attributes the 50–180 s
  iPhone load to the Neural Engine compile inside `MLModel(contentsOf:)` and
  offers two options, `encoderComputeUnits: .cpuAndGPU` (~1 s, no background
  execution) or warming the load "in a background task after launch". No
  prewarm API; `MLOptimizationHints` were benchmarked and regressed
  throughput. v0.17.7 is the latest release; HEAD changes nothing about load.
- Every surveyed app (WhisperKit/WhisperAX, Dictus, FluidVoice, VoiceInk)
  loads once in the long-lived main process, keeps the model resident, and
  hides the first compile behind a launch-time preload or a visible
  "preparing" screen. Dictus routes a cold-cache keyboard dictation into the
  foreground app. None relies on a `BGProcessingTask`. iOS suspends and kills
  our app between dictations, so "keep it resident" is not available to a
  keyboard-started dictation; the cloud fallback plus a continued load is the
  equivalent.

## Verification

- `scripts/build-ios.sh` (Simulator Debug) succeeded; `scripts/test.sh` 143
  tests, 0 failures. A scratch test (deleted) covered the hand-off: a cold
  load returns nil after 5 s, the warm-up adopts it, `abort` leaves it alone,
  the next dictation takes the claim, waits for the load and transcribes
  locally, the session is stopped once and the stores end free.
- Mac, signed and notarized 0.6.7 built with `scripts/release.sh`
  (`SKIP_TESTS=1` after the test run above), installed to `/Applications`,
  on the M2 Mac mini. The mini has no microphone; the system default input
  was pointed at the Jump Desktop Audio loopback and an 8-channel copy of a
  10 s recording was played into it (speech reaches input channel 0 only
  when every output channel carries it). Dictations ran through
  `voiceiq://start-hands-free` and `voiceiq://stop`.
  - A silent recording ends as `DictationOutcome.silent` and aborts the
    load, which kills the helper ("Local helper disconnected"); that is the
    pre-existing abort path, not the fallback.
  - Cold (`~/Library/Caches/io.blue.voiceiq.localspeech/com.apple.e5rt.e5bundlecache`
    deleted), 5.3 s recording: 5 s after "transcribing" the log shows
    "On-device model still loading 5s after the recording; using cloud
    transcription, load goes on as a warm-up"; the helper then logs
    "Parakeet cold load complete in 13.33s"; Gemini transcribed in 5.2 s and
    the text was inserted 12 s after the stop. Waiting for the local load
    would have taken about 8 s here, so on the Mac the fallback is a wash;
    on the phone it saves about 45 s.
  - Next dictation one minute later, new helper process: "Parakeet cold load
    complete in 0.15s", local transcript of 62 characters, confidence 0.993.
    The adopted load wrote the prepared copy and it carried across processes.
- Not exercised: the iOS hand-off, the held mic session and the new iOS log
  lines on a device. The simulator loads in about three seconds without the
  Neural Engine and has no `BGTaskScheduler`. The owner needs the build on the
  phone and one more overnight idle.

## Where the prepared copy lives, and the CPU encoder

Owner's follow-up: the OS and the app did not change between a fast and a
slow load hours apart, so "only an OS or app update drops the cache" cannot
be the whole story. He asked for the cold load itself to be faster, with
restricted APIs allowed (TestFlight only).

Measured on the M2 Mac mini with a throwaway SwiftPM tool
(`.amp/in/scratch/coldload`, FluidAudio 0.17.7, the installed model files, a
10.5 s recording; `coldload <modelDir> ane|cpu|gpu <audio>` and
`coldload ctc ane|cpu <ctcDir> <audio>`):

| Encoder | Parakeet cold load | reload | decode 10.5 s | CTC cold load | reload | spot |
|---|---|---|---|---|---|---|
| ANE (`.cpuAndNeuralEngine`, the default) | 13.0–13.5 s | 0.11–0.21 s | 0.08 s | 14.6 s | 0.19 s | 0.16 s |
| CPU (`.cpuOnly`) | 2.96 s | 0.11 s | 0.24 s | 2.14 s | 0.18 s | 0.21 s |
| GPU (`.cpuAndGPU`) | 1.34 s | | 3.5 s first, 1.4 s after | not measured | | |

Same transcript on every unit. Decoder and joint stayed on the ANE in every
row; their compiles are inside the CPU row's 2.96 s.

Where the warm state is: the only file the compile writes is
`Library/Caches/<id>/com.apple.e5rt.e5bundlecache/<OS build>/<key>.bundle`
(36 MB; the ANE part is a 6.6 KB `.e5` plus `model.anehash`, the large files
are the BNNS CPU programs). The warm state survives `mv` of the bundle
directories, `touch`, re-inoding one file, and `killall aned
ANECompilerService`. A byte-identical `ditto` restore of the whole cache
directory, taken right after a compile, gives a cold load again. Conclusion
(inferred, matches `m0at/ANEtransformers`): the compiled ANE program is held
by the ANE driver, keyed by the anehash plus some identity of the cache
entry; the disk cache is an index to it, not a copy of it. Nothing on disk
can be saved and put back, so a snapshot/restore trick is out, and on iOS the
driver evidently drops the program after hours of idle. Core AI
(`AIModelCache`, `.persistent`, `coreai-build`) was checked too: an `.aimodel`
can only come from `coreai-torch` on a PyTorch export, there is no Core ML to
Core AI import, so it would mean re-converting Parakeet from NeMo. Not done.

Decision: dictation runs both encoders on the CPU (`DictationCompute`,
`ParakeetSession.load`, `ParakeetVocabulary.loadModels`, which replaces
`CtcModels.loadDirect` because that pins the ANE). Both platforms, so one
code path and one set of numbers. The cold load drops from about 28 s (M2,
both packs) to about 5 s; the phone figure waits for the owner's next
TestFlight log, which now prints `encoder=cpu` in "Parakeet cold load
complete". Meetings (`LocalMeetingJob`) and Nemotron keep the ANE: a meeting
pays the compile once an hour and the ANE saves power; Nemotron was not
measured. The 5 s cloud fallback stays as the backstop. Nothing user-facing
changed otherwise. `.cpuAndGPU` was rejected: its first decode costs 3.5 s on
the Mac and the GPU is not allowed while an iOS app is in the background,
which is where a keyboard dictation is processed.

Verification of the CPU encoders: `scripts/build-ios.sh` ok, `scripts/test.sh`
143 tests, 0 failures. Mac: signed and notarized 0.6.7 rebuilt with
`scripts/release.sh`, installed to `/Applications`, prepared-model cache
deleted, same loopback recipe (default input set to "Jump Desktop Audio",
`afplay` of an 8-channel 48 kHz copy of the 10.5 s recording,
`voiceiq://start-hands-free` / `voiceiq://stop`), one dictionary term
written to `dictionaryEntries` so the CTC pack loads too.

| Run | Load | Decode (14 s audio) | Result |
|---|---|---|---|
| Cold, Parakeet only (no dictionary) | 2.50 s, `encoder=cpu` | 0.19 s | local, 125 chars, confidence 0.998 |
| Cold, Parakeet + CTC pack | 4.71 s, `vocabulary=true` | 0.43 s incl. 8 CTC detections | local, 125 chars, confidence 0.999 |
| Next dictation, same helper | 0.12–0.21 s | 0.40 s | local, 125 chars |

Before this change the same cold run took 13.3 s (Parakeet alone) and went to
the cloud at the 5 s mark. The cloud fallback did not trigger in any run above.
The test term and the input-device change were reverted afterwards. Not
exercised: the phone. The owner's next TestFlight log shows the iPhone CPU
cold load and decode time in "Parakeet cold load complete … encoder=cpu" and
"Parakeet complete … in Ns".

## Follow-up: stage split in the session log

The owner's log after the fix (2026-10-26 21:45, 11.5 h idle) shows the load
down to 3.3 s, but "processed in 8.4s" for a 66 s recording and 7.7 s for a
36 s one. The log could not say whether that was the decode, the cleanup
request, or the insert. `DictationCoordinator` now measures the three
stages (`StageTimes`, `onStageTimes`) and the iOS app logs them as
"finalize Ns, decode Ns, cleanup Ns, insert Ns" right after "processed in".
Review added the finalize stage (trailing speech and mic teardown, which
"processed in" counts but the first split did not) and a source flag on
`DictationStreaming` so a cloud live socket's result is not logged as a
decode. Verified by
`scripts/test.sh` (143/0) and the iOS and Mac builds; the line itself needs
the next TestFlight build and a real dictation on the phone.
