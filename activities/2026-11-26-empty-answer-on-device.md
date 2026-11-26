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
- On the on-device route, a dictation whose model failed and went to Gemini
  may run Pro once more if Gemini then answers empty. That costs time, not
  calls.

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
