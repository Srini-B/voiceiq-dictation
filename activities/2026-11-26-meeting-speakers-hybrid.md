# 2026-11-26: Meeting speakers, hybrid of Gemini and the on-device speaker model

## Why

cyron rates VoiceiQ meetings under 40 and records important meetings in
Granola. The goal is 90 or more on each meeting score in `eval/SCORECARD.md`:
participants named (M1), who spoke when (M2), who said what (M3), transcript
accuracy (M4, cpWER), notes (M5) and UI (M6). The Chrome extension, the
previous source of names, is being removed, and Gemini stays the online
transcriber. The research and its corrections are in the artifact
"Meeting speakers: verified research and revised plan" (thread
T-01a216c8-4952-74a8-b308-cbc7879e8a45).

## What changed

- **Per-track requests.** On an online call with an echo-free mic,
  `MeetingTranscriber.transcribeTracks` sends the mic alone (every word is the
  note owner's) and the far side alone. Otherwise the old mixed request runs.
  Measured on AMI ES2004a set up as a call: the mixed request lost one of four
  people and put 73.5% of words under the right person; the far side alone
  found all three remote voices at 83.8%.
- **`incomplete` replies.** A request Gemini ends with status `incomplete`
  (seen when a sparse track was sent with its silences) is sent again as two
  halves, instead of failing the meeting.
- **Far side split on every call.** `splitFarSide` runs whenever the
  on-device speaker model (pyannote community-1) has segments; it no longer
  needs a head count from the extension.
- **Paragraphs.** A turn longer than 20 s ends at its next sentence end.
- **Names.**
  - `ScreenSpeakerNames.byElimination` gives the last unnamed far-side voice
    the last unmatched calendar invitee, when the invite lists as many people
    as there are far-side voices and that voice said 10 words or more.
  - The notes request accepts a single address followed by an answer in the
    very next turn, when the name is an invitee or on-screen name.
  - `CallWindowText.lines(pid:browser:)` reads only the meeting window in a
    browser, not every tab's window.
- **Notes.** `meetingNotes` retries once when the reply is not parseable
  JSON (2 of 14 requests on main failed this way), and the parser ignores
  text after the JSON object.
- **Eval.** `eval/meetings/` runs the same steps as `MeetingEngine.finish` on
  AMI ES2004a and four synthetic `say` meetings, each with an echo variant,
  and writes the output `eval/meetings/score.py` (PR #80) reads.

## Decisions

- **The speaker model downloads without asking.** It is 21.6 MB, takes about
  a second, and nothing it hears leaves the Mac. A prompt would leave most
  calls unsplit, since the extension that used to supply the count is gone.
- **No voiceprints in this change.** There is no confirm-speaker screen yet,
  the false-accept rate across meetings is not measured, and stored
  voiceprints need a consent screen. Synthetic naming reached 100% without
  them.
- **Single address counts as evidence.** The prompt rulebook asked for a name
  in two or more turns. In gallery-view calls each person is often addressed
  once ("Sarah, you first."), and in two of four synthetic meetings every far
  voice stayed "Speaker N". Being addressed still names the listener, never
  the speaker, and the name must be on the invite or the screen.
- **No active-speaker reading or visual ring detection.** Both need a live
  call to probe the Accessibility attributes of Meet, Teams, Zoom and Slack.
  That is later work.

## Verification

Eval on an Amp Mac satellite (macos-27; the lobsters-mac-mini runner was not
listed), scored with PR #80's `score.py` (cpWER for M4). Mean of AMI
ES2004a and eight synthetic meetings:

| Run | M1 | M2 | M3 | M4 |
| --- | --- | --- | --- | --- |
| main, speaker model downloaded | 95.0 | 92.2 | 87.8 | 84.0 |
| this branch | 98.9 | 97.6 | 94.1 | 92.8 |

main without the model scored 78.3 / 80.6 / 76.9 / 68.3 on six meetings.
Two runs of the branch gave the same numbers.

AMI ES2004a alone: main 70.0 / 54.1 / 48.1 / 23.3, branch 90.0 / 84.3 /
80.8 / 77.0. AMI's plain WER is 33% without fillers, so the remaining M4 gap
is transcription, not speakers. One stray voice of 39 words costs M1 10
points.

The AMI reference had HTML entities (`we&#39;ve`) until `prepare.py`
unescaped them; the numbers above use the fixed reference.

`swift test --package-path VoiceIQCore`: 212 tests, 0 failures. The VoiceIQ
(macOS) and VoiceIQiOS (simulator, arm64) schemes build unsigned. A live call
was not tested.

## Rollback

Revert the merge commit. Meetings recorded with the branch keep their
`mic-N.json` and `far-N.json` caches; main ignores them and transcribes again.
