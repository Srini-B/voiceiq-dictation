# 2026-11-27: Meetings are Gemini-only; unreachable Gemini means wait

## Why

The Hex watch's offline eval (PR #117) scored VoiceiQ's on-device meeting
transcription on six AMI meetings (171.6 min): M1–M4 87.5 / 45.7 / 69.6 /
57.3. The scorecard allows on-device work only where it scores 90 or more,
and Gemini scores far higher on the same meetings. The dispatcher (thread
T-01a1cd83) decided to remove the On device choice for meetings and to keep
the on-device speaker model, which only splits the far side's voices.

## What changed

- **No Meetings source setting.** The Meetings row under Settings → Speech
  is gone, along with `SettingsStore.meetingSource` and the meeting rows of
  the on-device model controls and privacy settings. A stored
  `meetingTranscriptionSource` is ignored. `MeetingEngine.process` always
  sends the tracks to Gemini (`MeetingTranscriber`), and the notes are
  always written by Gemini. "Writing rules and notes" is now "Writing
  rules", for on-device dictation only.
- **`LocalMeetingTranscriber` removed.** Its word and speaker joins, which
  `MeetingTranscriber.splitFarSide` uses, live on as `FarSideSpeakers`.
  `LocalMeetingJob` keeps its speech step because the offline meeting eval
  (#117) still measures it.
- **Waiting for Gemini.** A meeting that fails because Gemini is out of
  reach (no key, offline, a timeout, a transport error or 5xx, a per-minute
  rate limit; Neon review) is saved with
  `MeetingMeta.waitsForGemini`, the step it still needs. `MeetingEngine.transcribeWaiting` sends it
  again at launch, when the network comes back (`NWPathMonitor`), and when
  a key is saved (`KeychainStore.saveAPIKey` posts `.apiKeySaved`), and on
  a timer while it waits with a key (5 minutes, doubling to an hour), since
  Gemini recovering or a quota reset raises no other signal. The failed
  step is saved (`GeminiStep`, Codex review): notes alone when notes
  failed, so transcript edits stay and a synced meeting without audio
  recovers; a new transcript when transcription failed, so a Redo
  transcript and notes is not silently turned into notes only. The Mac
  list shows "Waiting for Gemini" and a grey clock instead of a red error;
  the iPhone list shows "Waiting". A rejected key or a refusal still fails
  for the user to fix.
- **Settings.** The speaker model gets its own "Meeting speakers" group,
  shown while it is on disk, so it can be deleted. It still downloads
  without asking (cyron's decision of 2026-11-27).
- **Release notice** `release-notes/0.7.18.notice.md`: users who had set
  Meetings to On device are told their meeting audio now goes to Gemini.

## Verification

See the PR. `testOnlyUnreachableGeminiMakesAMeetingWait` checks which
failures wait and which do not.

## Rollback

Revert the merge commit. Meetings saved with `waitsForGemini` read as
ordinary failed meetings in older builds.
