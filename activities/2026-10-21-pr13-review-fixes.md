# 2026-10-21: PR #13 review pass

CodeRabbit reviewed [PR #13](https://github.com/Srini-B/voiceiq-dictation/pull/13)
(0.6.3) with 14 comments. All were valid against the code; this is the fix pass.

## Decisions

- An on-device meeting on iPhone and iPad now has a deadline. `LocalMeetingJob`
  ran in-process with no limit, so a stalled Core ML call left the note in
  Transcribing, never fell back to the cloud, and kept the Fluid Speech Mini
  session so dictation could not use it. The Mac helper already killed itself
  after `max(600, 3 × audio)`. That budget moved to
  `TimeoutPolicy.localMeeting(audioSeconds:)`, the one file allowed to hold
  deadlines, and `LocalMeetingTranscriber`'s `Job.run(deadline:)` applies it
  on both platforms with the dictation pattern (`LocalTranscriber.bounded`):
  the first of job result or timer claims the continuation, the stalled task
  is cancelled and abandoned, never joined, and the meeting throws
  `Failure.timedOut` so `MeetingEngine` takes its cloud route when a key is
  stored. On the Mac the helper is killed at the same second, so the in-core
  deadline is a backstop there. `Job.cancel()` no longer waits on an
  abandoned run, so deleting the model does not stall behind it.
- `LocalMeetingTranscriber.acquire` throwing `busy` (the models stayed with a
  dictation for ten minutes) now falls back to the cloud when a key is
  stored, like a failed local decode does; without a key it is the meeting's
  failure reason. Cancellation still propagates.
- Local meeting audio is metered under `.meetingTranscribe`, not the
  dictation stage, so the Cost pane's meeting totals carry on-device work at
  $0 instead of the dictation totals.
- `writeMix` skips an empty final slice instead of unwrapping its base
  address.
- `MeetingFailure` strings pick the platform's names at compile time:
  "Settings → Advanced" and "Meetings" on the Mac, "Provider & Keys" and
  "Notes" on iPhone and iPad; the banner noun is "Meeting" or "Note".
- Docs: CONTRIBUTING ground rule 10 lists the ElevenLabs host; cost tracking,
  privacy verification, README pricing, the `keyterms` scope (dictation modes
  only; meetings ask for speaker labels), and the live-socket note name
  ElevenLabs correctly; the mobile download step no longer offers Nemotron;
  the local-meetings report scopes the two-model flow to the Mac.

## Verification

- `swift build` and `swift test` in `VoiceIQCore/`: 143 tests passed.
- iOS Release simulator build (iPhone 18 Pro Max) succeeded; the
  deadline path itself was not exercised, since the simulator cannot be
  fed a meeting recording and a stall cannot be forced.
- The Mac release build was not rebuilt; the Mac helper's timeout value is
  unchanged, only its home.
