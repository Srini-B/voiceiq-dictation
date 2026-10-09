# Cleanup recovery and download layout

2026-10-09. Follow-up to the Parakeet replacement.

## Cleanup recovery

The failed 13:13 cleanup had an 18.21-second request budget. Its duplicate
started 8.19 seconds later but received only 10.02 seconds. Both expired together.
A fresh request still has the entire prompt to process; it now receives the full
budget. First success still returns immediately. Worst-case recovery can wait
longer, bounded by the request budget plus the retry delay (maximum 80 seconds).
This fixes premature retry expiry, not provider availability or normal latency.
Cancellation now throws out of the retry timer and cannot start another request.

A temporary probe used the production retry race and deadline helper. With a
stalled first request and a retry needing 14 seconds (time-scaled), the previous
budget timed out and the full budget returned the exact expected text. Fast
success and cancellation passed too. No permanent tests were added.

Re-read archived thread T-01a10cbb-37ff-72fb-971c-08d25357d206. Gemini 3.8 rejected
minimal thinking in its live probe. Corrected the inaccurate code comment that
claimed low had measured faster; the model setting itself remains unchanged.

## Download layout

The shared macOS/iOS view now gives progress the available row width. A separate
title/percentage line sits above a bar and centered x-circle cancel icon. The
button retains an accessible Cancel download label.

## Memory investigation

Re-read T-01a0fb4f-1f7e-72b7-b803-632e944c5487 specifically for memory ownership,
measurement, and commits. The earlier WhisperKit experiment used a separate Mac
XPC helper exiting after 60 seconds idle (0.5 seconds after explicit shutdown or
diarization), not a five-second Parakeet timer. It was discarded uncommitted.
Searches across all fetched git refs for LocalSpeech, WhisperKit, Parakeet and
unloadModels found no retained implementation commits.

FluidAudio 0.17.7 source inspection confirmed no global MLModel cache. Manager
cleanup nils its aggregate and individual model references; long-recording worker
clones are local and joined before returning. A shared MLMultiArray buffer cache
is cleared asynchronously. Core ML runtime caches are outside app ownership.

A temporary in-process library probe ran three successful synthetic transcriptions
through ParakeetTranscriber and sampled Mach TASK_VM_INFO phys_footprint. Baseline
was 22,823,632 bytes. Five seconds after each completion it was 65,323,824,
65,995,568, and 56,345,392 bytes. This is not a whole-system or ANE-memory measure,
nor proof of return to baseline. The app releases model references immediately
before cleanup and only loads on dictation start; it does not retain a warm model.
The five-second physical-memory guarantee is not established. No process-exit
design was added to iOS or macOS in this follow-up.

## Verification and delivery

Temporary probes passed and were removed. All 143 existing tests pass. The iOS
simulator build passes. Installed Mac, iPhone and iPad progress screenshots were
inspected; the icon and progress-bar centers align. Clicking the Mac cancel icon
returned to Download with the toggle still on. The Mac mini's original off
preference was restored after verification.

The release flow signed, notarized and stapled the app and DMG. Installed on Mac
mini and MacBook; their executable hashes match and signatures validate. MacBook
automation remains permission-blocked, so its running process still needs a
manual quit/reopen. No paid provider call was replayed; the recovery check uses a
controlled delayed response. Nothing is committed, pushed or publicly released.
