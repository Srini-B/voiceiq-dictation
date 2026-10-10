# Parakeet replacement and cleanup timeout investigation

2026-10-09. The user rejected Whistle's recognition quality and requested its
removal on all supported platforms. Parakeet v3 must be an explicit on-demand
download, independently deletable with local transcription still enabled.
Missing models must use cloud transcription. No model may stay warm between
dictations.

## Prior experiment

Read archived thread `T-01a0fb4f-1f7e-72b7-b803-632e944c5487` before implementation.
It used WhisperKit 626 MB and optional meeting diarization, not Parakeet ASR.
The uncommitted experiment was discarded. Reused its staging, pinned integrity
checks and cloud fallback approach, not its 60-second XPC idle lifetime or
meeting scope.

## MacBook records, Asia/Kolkata

Read-only examination of the recording metadata, transport logs, usage database
copies and unified logs confirmed these sessions:

| Started | Recording | Local raw length | Cleanup outcome |
|---|---:|---:|---|
| 13:08:23, `2631555D-5148-4E9B-B110-61ED1A0FFE81` | 27.5 s | 206 characters | Gemini 3.8 Flash returned 187 characters in 10.829 s |
| 13:13:58, `F06329BA-BEE4-4D96-92C3-76DEDED61D9E` | 128.9 s | 775 characters | Both cleanup attempts timed out; raw transcript inserted |

The second session's first attempt lasted 18.219 seconds and its second lasted
10.020 seconds. Neither received a first byte or response body. The formula
`12 + characters/350 + 2*images` gives 18.21 seconds for 775 characters and two
images; the second attempt starts after 45% of that budget. TCP/TLS setup was
46–77 ms. A later cloud real-time session also hit this failure, so Whistle is
not its cause.

The earlier successful cleanup used 1,044 thinking tokens with thinking level
`low`. Longer reasoning is a plausible contributor to response latency, but the
timed-out call has no usage response or provider-side trace to prove that cause.
No paid requests were replayed. Kept the deadline and model configuration rather
than claiming that waiting longer fixes latency. Cleanup sends prompt text and
JPEG images, not audio. Cloud transcription fallback sends saved audio.

## Implementation decisions

- Removed Whistle weights, runtime sources, vendored binaries and embed scripts.
- Pinned FluidAudio 0.17.7 and the Core ML Parakeet v3 model revision recorded in
  `ParakeetManifest.swift`. The 21 files total 483,105,645 bytes.
- The downloader reports byte progress, verifies sizes and SHA-256 off the UI
  thread, and publishes atomically. Failed/cancelled staging files are removed.
- Settings share download/delete controls across macOS and iOS/iPadOS. Deletion
  cancels and joins a registered session before deleting files; the preference
  remains enabled. A busy local engine uses cloud rather than doubling memory.
- Load only at dictation start. Use the complete-recording API after the CAF
  drains, with disk-backed processing for long audio. FluidAudio's streaming
  API can silently return partial text after window failures; that is why this
  integration does not use overlapping-window streaming.
- Release model references immediately after local transcription, before cleanup,
  and on abort. No retained warm model or delayed-unload timer. Core ML's own
  cache/RSS behavior is not a guaranteed five-second physical-memory release.
- Keep all dictation modes and the existing cloud cleanup provider. Meetings
  and history entries remain unchanged.

## Verification

The downloader's real 483 MB download, progress, cancellation, integrity failure,
HTTP 404, restart with missing files, and deletion while a session was registered
were exercised with disposable probes. No permanent tests were added. The
integrated Swift package builds and all 143 existing tests pass.

Starting two build scripts together caused an XcodeGen output collision. Both
failed before compilation; rerunning project generation serially resolves it.
The temporary inference probe transcribed synthetic speech and both MacBook
recordings with the real downloaded model. It checked expected phrases in the
synthetic sample, exclusive model ownership, repeated use, and deletion during
loading. It passed and was removed. The first-ever Core ML load was slow;
subsequent loads benefited from OS caches. These checks are not a comparative
latency benchmark or a measured word-error-rate evaluation.

`scripts/release.sh` passed signing, Apple notarization and stapling for both app
and DMG. The installed Mac mini app passed UI checks for off, missing, download
progress, cancellation, ready, and deletion with the local toggle still on.
Screenshots were inspected. MacBook installation has the same executable hash
and validates signing and stapling. MacBook automation is permission-blocked;
the old running process must be quit and the replacement reopened by the user.

iOS simulator and unsigned device-target builds passed. iPhone and iPad settings
were inspected. The iPhone simulator completed a download and deletion with the
toggle on. A reused Xcode output contained an obsolete Whistle framework; a
fresh DerivedData build was installed on both simulators and their installed
bundles checked for Whistle and bundled Core ML weights. Neither was present.
Physical iPhone/iPad inference and installation were not performed.

Cleanup timeouts were diagnosed, not fixed. No provider response exists to prove
the server-side cause. App-owned model references are released before cleanup;
OS-managed Core ML cache reclamation within five seconds remains unverified.
Changes are uncommitted and unpublished. No TestFlight or public release was
created. Recordings, credentials and existing history were preserved.
