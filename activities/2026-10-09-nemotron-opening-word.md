# Nemotron opening-word investigation

The user reported that the 17:01:26 MacBook dictation omitted “Once.” The
32.394-second recording is session `01FE6629-12C5-4C79-A660-82CD4EEB842F`.
Its raw transcript starts “The model is removed,” so cleanup did not cause the
omission.

## Evidence

- Listening to the saved opening found “Once” audible, with a clipped-sounding
  onset. This does not establish how much audio preceded microphone capture.
- Replayed all saved samples through the installed signed, notarized helper on
  the Mac mini and MacBook. Loading finished before the first append, eliminating
  model-startup buffering as an explanation for the replay. Both reproduced the
  exact original transcript, including the missing word.
- Leading silence of 250, 500, or 1,000 ms restored “Once.” However, 500 ms also
  removed the later question “When does the model.” Padding changes recognition
  and is not a reliable fix. No padding workaround was added.
- On the MacBook, the first fresh helper process loaded in 0.687 seconds. Three
  subsequent fresh processes loaded in 0.217–0.229 seconds. Each produced a
  nonempty final transcript. These are observed load times with existing disk
  caches, not first-install, post-reboot, or stop-to-paste benchmarks.
- Inspected FluidAudio 0.17.7. Its streaming API consumes complete chunks and
  flushes the remaining samples at finish. It already initializes left context;
  caller-supplied silence is not a documented requirement. Upstream issue #838
  discusses words omitted despite audio being consumed. This is related evidence,
  not proof of the exact decoder defect in this recording.

## Startup contract

The coordinator creates the local transcriber and installs its PCM sink before
starting capture. The model loads asynchronously. Captured audio waits in a
30-second ring and is drained in order after load. A dropped byte or mismatch
against the saved recording disqualifies the local result and uses cloud fallback.
This protects captured audio, not speech spoken before microphone capture starts.

Models are released after each dictation. On Mac, the helper exits after 60 idle
seconds to reclaim runtime allocations. No microphone recording or model warmup
was added while idle.

At the end of this investigation, no runtime code had changed. Startup buffering
did not explain the reproduction. The subsequent fix and signed-build results
are recorded in [Nemotron speech boundaries](2026-10-09-nemotron-speech-boundaries.md).
