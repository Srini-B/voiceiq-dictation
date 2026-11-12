# Play and Download for every recording

2026-11-12.

## Why

The maintainer asked for Play and Download wherever the apps show a recording, on the
Mac and iPhone, disabled when the audio is not on the device. They also asked
whether meeting audio is kept like dictation audio, so a meeting with a wrong
transcript can be transcribed again with the provider chosen now.

## What we found

- Meeting audio was already kept. `MeetingEngine` writes `mic.caf` and
  `system.caf` to the meeting's folder and only deleting the meeting removes
  them; audio retention covers dictations only.
- Transcribing a meeting again already existed: **Redo transcript and notes**
  on the Mac, **Redo → Transcript and notes** on iPhone
  (`MeetingEngine.retry(id:fresh: true)`). It drops the cached windows and
  transcribes through `SettingsStore.meetingSpeechEndpoints`: ElevenLabs
  Scribe v3 when it is the transcription provider, otherwise
  `meetingProviders` with the provider selected now first. The window cache
  is named after the first endpoint, so a redo after switching never reuses
  the other model's windows. (Notes always come from `meetingProviders`.)
- Before this change, only the Mac dictation detail could play audio, and its
  button was hidden rather than disabled. Nothing could download audio, and
  meetings could not be played at all except one turn at a time in Assign
  speakers.

## What changed

- `RecordedAudio` (VoiceIQCore) names a recording's audio and renders it once
  to an AAC `.m4a` in the temporary folder. A meeting is mixed through
  `CallAudio.samples`, the transcriber's levelled and ducked mix, without
  touching `mic-aec.caf`. `RecordingPlayer` plays it.
- Mac: `RecordingAudioButtons` (Play/Stop and Download) in the dictation and
  meeting detail headers. Download saves to Downloads and shows the existing
  export message (`ExportToast`, now shared with the dictation detail).
- iPhone: an Audio card with Play and Download (a share sheet with the
  `.m4a`) in the dictation and note details.
- Redo transcript and notes is disabled when the meeting's audio is missing.

## Verification

Not built yet: it is tested in one combined Mac build with the ElevenLabs
Scribe v3 work. `RecordedAudioTests` covers the dictation and
meeting `.m4a` lengths and the unavailable cases.

## Follow-up from the combined build (2026-11-12)

The combined Mac test run on 0.7.1 (75) found the Mac dictation detail's Retry
transcription still enabled with the audio gone, where `RetryQueue` can
only answer "failed" for a finished dictation. The iPhone offered it too
whenever a raw transcript existed. Both now use `RetryQueue.canRetry`: the
recording is there, or an unfinished dictation already has its words.
Covered by `RecoveryClipboardTests.testRetryIsOfferedOnlyWithSomethingToRetry`.
