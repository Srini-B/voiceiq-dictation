# 2026-11-02: Live dictation with Nemotron 3.5 Transcribe on the Mac

## Why

The owner wanted Nemotron 3.5 Transcribe (Claude with the DeepInfra key) to
show text while speaking, like Fluid Speech Mini and Pro, and accepted the
higher DeepInfra bill. After a first build that only previewed text, they
asked for the streamed pieces to be the actual transcript.

## Decisions

- DeepInfra has no streaming endpoint for this model, so
  `DeepInfraLiveTranscriber` re-sends the open tail of the recording after
  each second of new audio, one request at a time, and locks text in at a
  pause once the tail reaches 12 s. On stop it sends only the remaining tail.
  The transcript is the locked-in text plus that piece.
- The first design cut between words using `verbose_json` word timestamps.
  In the installed app DeepInfra returned text and duration only (138 bytes
  for 5.9 s), so no cut was ever found, the tail grew to 20 s and a forced
  lock-in repeated a phrase ("keep moving as I Should keep moving as I go").
  Cuts now come from the audio: the longest quiet run of 10 ms blocks in the
  6 s before the last second, and a commit request carries exactly the audio
  before the cut, so nothing is heard twice.
- A cut first split the silence in half. Nemotron then wrote a dictionary
  word from the prompt ("VoiceiQ") into the silence. Each piece now keeps
  100 ms of the pause and the rest is dropped. That was one run of evidence:
  the word came back at the same spot in a later 50 s run of the signed
  0.6.24 build, and Claude cleanup turned it into "waveform in VoiceiQ". The
  pieces now drop a single-word dictionary term that stands alone at a
  piece's edge (`withoutLeakedTerms`). Greptile pointed out that the first
  version, which judged only by capitalization and punctuation, would also
  drop a spoken "VoiceiQ API works." It now needs audio evidence: an earlier
  preview that heard the same audio with more context and did not contain
  the term. Without such a preview the word is kept. Scratch tests (deleted)
  covered the leak, a spoken "VoiceiQ API works.", "Priya Kumar" split by a
  cut, and both no-evidence cases. Four 50 s runs of signed 0.6.24 builds
  with the filter came back without the leaked word.
- Greptile found that the pause finder judged quiet only against the
  quietest block, so speech over steady noise could count as one long pause
  and its middle would be dropped. A block now counts as quiet only below
  about -45 dBFS; otherwise the cut drops nothing.
- On stop, a request in flight is cancelled rather than waited for; the last
  piece covers its audio.
- The saved recording is still uploaded, as before, when three requests in a
  row fail, the last piece fails, or the received bytes do not match the
  recording.
- Off by default. The owner asked for it only when Real-time transcription
  is turned on, not by default. The toggle stays on by default for Gemini,
  OpenAI and on-device dictation, and now reads off for Claude with
  Nemotron 3.5 picked until the user changes it. The live path also needs
  the user's own setting (`liveTranscriptionChosen`), so an on-device
  dictation falling back to Nemotron 3.5 does not stream by default. A Mac
  where the toggle was ever changed keeps that choice.
- Mac only. iPhone and iPad have no live text, so there the pieces would add
  cost for a small speed gain.
- The coordinator now creates every streamer inside the dictation's
  `UsageMeter.scope`, so requests sent while recording are booked against
  the dictation (`liveTranscribe`) instead of "Other".

## Verification

Signed and notarized 0.6.23 builds from `SKIP_TESTS=1 scripts/release.sh`,
installed to `/Applications` on the Mac mini, Claude provider with the
DeepInfra key, dictation source set to Nemotron 3.5 for the test. `say`
speech (22 s and 50 s) was played into the Jump Desktop Audio loopback as the
default input; dictations ran through `voiceiq://start-hands-free` and
`voiceiq://stop`.

| Clip | Path | Stop to transcript | Stop to cleaned text | Audio billed | DeepInfra cost |
|---|---|---|---|---|---|
| 22 s | Upload (real-time off) | 3.3 s | 5.5 s | 22.5 s | $0.00075 |
| 22 s | Live pieces | 2.4 s | 4.4 s | 81 s | $0.00271 |
| 50 s | Upload (real-time off) | 4.1 s | 10.8 s (slow cleanup) | 50 s | $0.00167 |
| 50 s | Live pieces | 2.7 s | 12.5 s (cleanup retried) | 157 s | $0.00523 |

- 22 s, live: the raw transcript matched the upload's words with no repeats.
- 50 s, live: no repeats and no inserted word. One sentence boundary moved
  ("let Priya know second. The release notes"): `say` pauses are all about
  200 ms, so a comma pause tied with the sentence pause. Claude cleanup
  restored the sentence.
- The pill showed live text, captured with "hide pill from screen sharing"
  turned off for the test: "…uickly the final text arrives when the recording
  runs for a…" at 0:11.
- Usage rows carry the dictation's session ID with stage `liveTranscribe`.
- `scripts/test.sh` passed 143 tests. Scratch tests (deleted) covered the
  pause finder on noisy audio and the commit, preview and final-text flow.
- Test settings were restored afterwards: dictation source, input device and
  pill screen-sharing setting.

Opt-in verification, same signed build, toggle never set: with Nemotron 3.5
picked the Dictation pane showed Real-time transcription off; picking On
device showed it on, and back to Nemotron 3.5 off, and neither click saved
the setting (a first build saved the refreshed value through the toggle's
`onChange`, so the toggle now saves only through its binding). A dictation
then made one upload and no live calls. After clicking the toggle on it
saved `true`, and the next dictation made 10 live calls and no upload.

## Pill text contrast

The owner saw the live text on the pill as white on a light grey pill. On
macOS 26 and later the pill is Liquid Glass, which takes the brightness of
what is behind it, while the text colors follow the system appearance. In
dark mode over a white page the glass turned light grey under light text;
light mode over a dark window had the reverse problem. A scratch SwiftUI
board (deleted) compared the token colors, `.secondary` and `.primary` on
plain glass, tinted glass, and glass over a surface fill of 0.6, 0.75 and
0.9: only the fill kept the text readable in both appearances over white and
black. Untinted pills now draw `VoiceIQUI.Colors.surface` at 0.75 under the
glass. Tinted pills (notices) are unchanged. Checked in the signed build
with a white and a black window behind the pill, in dark and light mode: the
live text, timer and lock read clearly in all four.

Not verified: real microphone speech, a cancelled dictation, and the
fallback paths on a live network failure.
