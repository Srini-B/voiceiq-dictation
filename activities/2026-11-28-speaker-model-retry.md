# Speaker model: retry a failed prediction, then say so (2026-11-28)

## Why

On gate (a)'s eval, run on a heavily loaded Mac mini, the on-device speaker
model (pyannote community-1 through FluidAudio) failed in 4 of 9 meetings
(ami-ES2004a, s1, s3-echo, s4) with Core ML's "Unable to compute the
asynchronous prediction using ML Program". `MeetingTranscriber.splitFarSide`
logged it and kept AssemblyAI's far-side clusters, which in s3 put Sara and
Grace under one voice. Users got the same silent fallback. Load is the likely
trigger but was not confirmed.

## What changed

- `FarSideSpeakers.retrying` runs the model again when Core ML fails a
  prediction: after 2 s, then after 5 s with every model on the CPU alone
  (`LocalMeetingRequest.cpuOnly`). On the Mac each try is a fresh helper
  process. Other errors are not retried. The app (`MeetingEngine.farSideDiarizer`)
  and MeetingsEval both use it.
- A model that still fails leaves `transcribe-far-speakers-failed` in the
  meeting folder; the engine sets `MeetingMeta.speakersUnsplit`. The Mac
  shows a notice with **Split Speakers Again**, the iPhone a card with
  **Split speakers again**. Both run Retry, which reuses AssemblyAI's cached
  windows, so the split costs no new transcription. MeetingsEval prints a
  warning for such a meeting.

## Verification

A unit test forces the failure with a Core ML-domain error: two failures then
success split the far side (third try on the CPU) and leave no mark; three
failures keep AssemblyAI's voices and mark the meeting; another error is not
retried. Mac mini `swift test` and both builds.
