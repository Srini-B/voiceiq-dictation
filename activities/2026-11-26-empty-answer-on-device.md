# 2026-11-26: An empty Gemini answer writes Fluid Speech Pro's transcript

## Why

In the hard real-audio eval (`activities/2026-11-26-hard-audio-eval.md`,
PR #106), Gemini answered "no speech" twice on 5 of 451 clips that had clear
speech: 3 far-field clips from CHiME-6 and 2 whispers with background
talkers. The app's existing second chance re-sends the same audio, and in the
eval that re-send came back empty too. Fluid Speech Pro, run on the same
clips for free, heard 3 of the 5.

## What changed

- `GeminiTranscriptionService` takes an optional `onDeviceTranscript`
  closure.
- On an empty answer for a one-part dictation, if the closure returns words,
  they go through `write`, Gemini's text-only writing step, instead of the
  audio re-send. That is one call either way, and a text request is cheaper
  than an audio one.
- With no transcript (Pro not downloaded, busy, failed, or it heard nothing),
  the audio re-send happens as before.
- `LocalTranscriber.proTranscriptIfDownloaded` runs Fluid Speech Pro on the
  saved recording when Pro is downloaded, whatever the Dictation source. The
  Mac uses the helper and iOS runs it in-process.

## Evidence (saved outputs only, no new API calls)

Gemini's saved answers and Pro's and Mini's transcripts are from the eval
runs. Pro's text is what would go to Gemini's writing step. Its final
written form needs a paid call, which is on hold.

| Clip | Reference | Gemini (twice) | Pro transcript | Mini transcript |
| --- | --- | --- | --- | --- |
| CHiME-6 S02 5077 | Can you just use a wipe for the dining table? | empty | Can you just uh use a wipe for the dining table? | Can you just uh use a wipe for the financial? |
| CHiME-6 S02 5333 | That's a weird location. | empty | empty (re-send as before) | empty |
| CHiME-6 S02 3071 | There's my phone. And maybe it'll cool down in here, too. I have yet to sit on this chair. | empty | Use my phone. Maybe it'll cool down in here too. I have yet to sit on this chair. | There's my phone. Maybe it'll cool down in here too. I yet to sit on this chair. |
| Whisper, 25% background, ex02 00272 | Sorry, I'm not sure when that is, but today is Sunday, June fourteenth. | empty | Sorry, I'm not sure when that is, but today is Sunday, June 14th. | Sorry, I'm not sure what that is, but today is sun and juicy. |
| Whisper, 25% background, p058 | I will not stay here. God, we simply must dress the character… | empty | empty (re-send as before) | The trail starts and called for that silence… (invented) |

Pro gives 3 of 5 usable transcripts: one exact and two with one wrong word,
where Gemini gave nothing. Mini invents text on p058, so only Pro is used.

## Risks

- A recording in a language Pro doesn't cover (Tamil, for one) that Gemini
  answers empty would reach the writing step as Pro's English-sounding guess.
  No Tamil clip came back empty in the eval.
- A key press with nothing said while a TV, a call or a colleague is
  audible: Gemini's "no speech" is right, but Pro transcribes the
  background voice, and that text would be written and inserted. Before this
  change the re-send came back empty and nothing was inserted. Measured
  below: Pro writes words on 35 of 47 such recordings, and no level rule
  separates them from the clips Pro recovers. This PR stays open.
- Pro's load is bounded at `TimeoutPolicy.localColdLoad` (5 s). Past that,
  the audio is re-sent as before, so a cold Pro load can't hold the pill
  for minutes.
- On the on-device route, a dictation whose model failed and went to Gemini
  may run Pro once more if Gemini then answers empty. That costs time, not
  calls.

## Near-field gate: measured, none qualifies (PR parked)

Decision rule set by the integrator: merge with a level gate only if, on a
set of at least 40 key presses with no near-field speaker, the gate lets
through at most 1 false insert and still keeps at least 2 of Pro's 3
recoveries. A wrong insert costs more than a missed dictation, so the
false-insert limit wins a tie.

**Silent key-press set (47 clips, 3.3–10 s, built from audio already on
hand, no paid calls):**

| Kind | Clips | Source | Pro wrote words |
| --- | --- | --- | --- |
| Room | 11 | CHiME-6 dev Kinect stretches with no annotated speech (4 still hold unannotated talk) | 4 |
| Talk | 12 | CHiME-6 dev Kinect stretches of other people talking, away from the eval clips | 11 |
| TV | 8 | An eval utterance (Voice Arena, Svarah, Monsoon) with 0.5 s reverb, 10–25 dB under the near-field dictation level, over room tone | 8 |
| Call | 8 | The same through a 300–3400 Hz phone band | 5 |
| Under | 8 | The same with 0.8 s reverb (a farther talker) | 7 |
| **Total** | **47** | | **35** |

The near-field level is the median loudest 100 ms frame of 40 Voice Arena
dictations (−16 dBFS). Half of the mixed clips sit over a quiet room
(50 dB under that level), half over a CHiME-6 room as recorded. CHiME-6
zeroes some Kinect stretches; any stretch with a zeroed 100 ms frame was
skipped, because a key press never records digital silence.

Fluid Speech Pro (the app's pinned revision, loaded as `ParakeetSession`
loads it) ran on a Mac satellite over the 47 clips and the 5 empty-answer
clips. With no gate it writes words on 35 of 47 silent clips and recovers
3 of 3.

**Gates tried.** Each feature is computed the way the app sees the
recording, from 100 ms RMS frames (the ~10 Hz level tap):

- `snr`: the coordinator's `measuredSNR` (peak minus 10th-percentile
  floor, on the level curve that saturates at −20.8 dBFS);
- `peak`: the loudest 100 ms frame in dBFS;
- `p90`: the 90th-percentile frame;
- `p90 − floor`.

Each was swept on its own and in every pair:

| Gate | False inserts (of 47) | Recoveries (of 3) |
| --- | --- | --- |
| None (control) | 35 | 3 |
| Coordinator rule, `snr ≥ 8 dB` | 31 | 2 |
| Best `snr` threshold keeping 2 recoveries (≥ 18 dB) | 26 | 2 |
| Best of all, `peak ≥ −20 dBFS` (also the best pair) | 7 | 2 |
| Strictest that keeps ≤ 1 false insert (`peak ≥ −8 dBFS`) | 1 | 0 |

No threshold meets both limits. The two goals conflict: two of the three
recoveries are far-field CHiME-6 talkers, and so is the background talk.
5077 has an SNR of 0.3 dB, so the coordinator rule rejects it. The CHiME-6
background talk peaks at −4 to −38 dBFS, a range that spans the
recoveries' −14 to −21 dBFS. A level rule can't tell a far-field talker the user meant
from one the user didn't. Under the decision rule #107 stays open, and the
re-send of the audio stays the empty-answer path.

The chosen threshold would have been `peak ≥ −20 dBFS` (7 of 47 false
inserts, 2 of 3 recoveries), but it fails the limit, so nothing ships.

## Verification

On an Amp Mac satellite (macos-27):

- `swift test --package-path VoiceIQCore` passes 262 of 262, including the
  new `testNoSpeechAnswerWritesTheOnDeviceTranscriptInsteadOfResending`. It
  checks two cases:
  - with a device transcript, the transcript is written and the audio is
    sent once;
  - without one, the audio is sent twice and the result is empty.
- Unsigned `xcodebuild build` of VoiceIQ and VoiceIQiOS.

The lobsters-mac-mini runner was not used, because this work stays in one
thread.

## Rollback

Revert the PR. Both apps go back to re-sending the audio on an empty answer.
