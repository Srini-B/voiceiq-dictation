# Local speech process isolation

The user accepted a 60-second idle helper lifetime to reclaim Core ML runtime
memory left after releasing the model. The earlier discarded experiment used
WhisperKit and Nemotron diarization in a helper, not Parakeet ASR. Its process
boundary is reused conceptually; none of that discarded code is restored.

The macOS app now embeds a signed background application. Private framed JSON
pipes carry model/audio paths, frame count and transcript. Parakeet cold-loads
on dictation start, releases model references before returning text and exits
the helper after 60 idle seconds. No model remains warm during that minute.
Cancellation kills the helper and waits for exit, including during synchronous
Core ML load. Session IDs prevent a stale abort from killing a newer session.
Transport failures return nil to the existing saved-audio cloud fallback.

iOS/iPadOS retain in-process release. General child-process execution is not an
available application architecture there. No fixed-time physical-memory return
is promised for those platforms or for OS-owned accelerator caches on macOS.

## Verification

- `scripts/release.sh` passed all 143 existing tests and produced an accepted,
  stapled Developer ID app and DMG. The nested helper passed deep signature
  verification. A copy was installed for testing on the Mac mini.
- Installed signed helper transcribed a synthetic 4.44-second sentence correctly.
  A second load reused the process. Holding that session active for 62 seconds
  did not trigger the idle timer. After transcription, process exit was observed
  at 63.63 seconds, including shutdown. This proves helper-process reclamation,
  not system-wide Core ML cache reclamation.
- A 35.81-second synthetic recording retained its beginning, middle and final
  phrase through the full-recording chunked API.
- Temporary client probe passed load cancellation, stale abort, forced child
  death returning nil, and successful subsequent restart. The probe temporarily
  substituted the installed helper path because XCTest's main bundle is its
  runner; that substitution and the probe were removed. No cloud request ran.
- Host pipe closure exited a loaded helper. A mismatched frame count returned
  no transcript. The final unchanged core suite passed 143 tests again.
- iPhone/iPad simulator build passed. Physical iOS memory testing was not run.

## Nemotron comparison

No replacement was implemented. At Core ML conversion revision
`1a41b75758b0337ff67db7d5408280aaaf23074e`, the 2240 ms Latin bundle totals
612,042,646 bytes; the multilingual bundle totals 664,846,846 bytes. These are
model-file download totals, not runtime RAM or the full repository size.
Parakeet's current pinned download totals 483,105,645 bytes.

Nemotron supports native streaming and broader language coverage. The Core ML
conversion targets macOS 14 and iOS 17. Accuracy superiority over Parakeet v3
has not been established with comparable recordings. Provider sources are the
[NVIDIA model card](https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b)
and [Core ML conversion](https://huggingface.co/FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML).

Rollback is to reinstall the preceding notarized application; the helper adds
no settings or model-format migration. No commits, pushes or public release
were made for this change.
