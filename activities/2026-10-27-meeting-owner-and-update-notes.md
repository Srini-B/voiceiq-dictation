# 2026-10-27: Meeting owner mislabelled, and notes after renaming speakers

## Report

A 2.5-minute Google Meet call in Safari on the MacBook had three speakers.
The owner's turns were labelled with another participant's name (Sourabh
Saini), and the notes credited that person with what the owner said. Fixing
a name in Assign speakers left the notes as they were.

## Causes (from the meeting folder on the MacBook)

1. The owner was never marked "you". `MeetingTranscriber.markOwner` runs only
   when `CallAudio.isOnline`, which needed 20 s of far-side speech. This call
   had 15.9 s (the far side spoke little). The owner's id `s2` had 564 mic
   windows to 7 far-side ones, so the mic test would have found them.
2. With the owner an ordinary speaker, `ScreenSpeakerNames.match` could give
   them a name from the screen. "Sourabh Saini" was on screen in 5 of the 8
   snapshots taken while `s2` talked.
3. The call was recorded as `com.apple.WebKit.GPU` ("Safari Graphics and
   Media"), not Safari. macOS lists WebKit's XPC services as running apps; the
   GPU process captures the mic itself, so `CallDetector` checked it first and
   returned it as an unknown calling app. `ScreenNameSampler` found no window
   for it and read the whole display instead, so the names came from an email
   app (Imamuddin Khan, Nitin Madabushi, Praveen Kumar), and the notes listed
   them as participants.

## Decisions

- `isOnline` needs 5 s of far-side speech when the recording started on a
  detected call (`MeetingMeta.source` set), 20 s otherwise. A detected call is
  already known to be a call; the 20 s bar guards hand-started recordings of
  a room with something playing.
- `CallDetector` skips `com.apple.WebKit.*`. The browser is reached through
  the helper's responsible process, already in `inputPIDs`.
- The notes record the typed names they were written with
  (`MeetingMeta.notesSpeakerNames`). When the typed names differ, the meeting
  header shows **Update notes**, which calls the existing `regenerateNotes`.
  The `…` menu's Redo notes did the same work but nothing said it was needed.

## Verification

- Replayed the saved meeting (its audio and cached on-device words) through
  `callAudio`, `markOwner` and `ScreenSpeakerNames.match` in a scratch test
  (deleted). Before: speakers s1, s2, s3; `s2` named Sourabh Saini. After:
  `isOnline` true (19.2 s far side once the mic was echo-cancelled), the
  owner's turns are "you", the far side is s1 and s2, and no screen name is
  assigned.
- VoiceIQCore tests: 144 passed.
- WebKit skip: confirmed on the MacBook that `com.apple.WebKit.GPU` is listed
  by `NSWorkspace.runningApplications` and its responsible process is Safari.
  Not tested on a live Safari Meet call.
