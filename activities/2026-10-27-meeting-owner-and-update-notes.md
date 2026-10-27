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

## Follow-up: short words on calls (same day)

The owner asked that a one-word reply from someone else is kept and never
given to another speaker.

Each track of the same meeting, decoded alone with the installed on-device
model, against the meeting transcript (decoded from a mix of both tracks):

| Time | Each track alone | From the mix |
| --- | --- | --- |
| 14.0 s | far side "Yeah." over the owner | lost |
| 78.6 s, 82.3 s | far side, over the owner | lost |
| 110.2 s | far side "this.", owner "Okay." | "this." given to the owner, "Okay." lost |

Decision: on a call with an echo-free mic, decode the mic and the system
track separately (`LocalMeetingTranscriber.byTrack`). Mic words are the
owner's; system words are diarized among the other people. Calls whose mic
failed the echo check, and in-person recordings, still use the mix.

Verified by replaying the meeting through the new path with the installed
models: all four cases above now come out right. None of the 220 words on the
owner's track fell where only the far side was speaking, so no echo leaked in
as the owner's speech. VoiceIQCore tests: 143 passed.

Still open: telling two remote people apart uses only the diarizer. At 87.4 s
it marked both remote voices over the same half second, and the phrase there
was split between them. The cloud meeting path still transcribes a mix; it
re-reads the owner's side of an overlap from the mic, but a far-side word said
over the owner can still be lost there.

## Follow-up: words the diarizer heard two people on

Without a test call, the owner asked for the best rule available now.
`LocalMeetingTranscriber.settled` gives a far-side word that the diarizer
heard two people on to whichever of them said the nearest single-speaker
word in the same phrase. Replayed with the installed models on the Mac mini's
22 Oct calls: 36 of 2,252 words moved in a 4-person crosstalk recording,
mostly sentence fragments joining their sentence; 0 moved in two ordinary
calls. A wider first version (every uncertain word) moved 77 words,
including real one-word replies, and was dropped. Today's 87 s phrase stays
split: its second word had no overlap, only weak evidence for the other
speaker. Version 0.6.11 (56).
