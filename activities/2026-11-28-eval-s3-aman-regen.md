# 2026-11-28: Rebuilt s3-four-people's audio after a garbled TTS render

## Why

After gate (a), two synthetic meetings stayed under the M5 bar of 85, and
both trace to one misheard line. In s3-four-people, STT-3.7 heard Rahul's
"Fair point Grace. I can run it on the Spanish segment for one more week." as
"One more the second the kitchen". In s4-names-unsaid-echo, it heard
Jordan's "Usage numbers by Friday then" as "You'll set numbers by Friday
then". No AssemblyAI model heard either line correctly: STT-3.7 batch,
Universal-2 and STT-3.7 Realtime were each run twice. The release thread
asked for a check by a recognizer outside AssemblyAI before changing any data.

## Check

whisper.cpp large-v3 (q5_0, in an orb, at no cost) and a model that listened
to the audio, each run on the line alone and on about 20 s around it:

| Line | whisper large-v3 | Listening model | Verdict |
|---|---|---|---|
| s3 Rahul, Aman, `system.caf` 29.37–32.14 s | "Fair point Grace. One more the second the Kicharda." | "one more the second the kitchen the" | the audio is garbled |
| s4 Jordan, Fred, `mic.caf` 64.41–70.69 s, plain and echo | correct | correct | the audio is fine; AssemblyAI mishears it |

Jordan's line in the meeting is sample-identical to a fresh `say -v Fred`
render, so its audio was left alone. A fresh `say -v Aman` render of Rahul's
line is 4.07 s long and identical across 3 renders, and both whisper and the
listening model hear it correctly. The copy in the meeting was 2.77 s.

## What changed

- `~/evaldata/s3-four-people` and `-echo` on lobsters-mac-mini were rebuilt
  with `prepare.synthetic` run from Terminal.app. From the runner, `say` with
  Aman fails, because macOS blocks access to the SiriTTS group container.
  The old data is kept as `*.v1`.
- The old renders were bad in more lines than this one: each of Rahul's three
  Aman lines changed length in at least one of the two copies, and the old
  plain and echo copies also differed from each other. Every other
  voice's line is sample-identical to the old data at its shifted time. The
  new plain and echo copies have identical timings, and their `system.caf`
  is byte-identical. The script, `input.json`, decisions and actions are
  unchanged.
- The eval README now says to run `prepare.py` from Terminal.app and to check
  every new render. `prepare.py` renders the meetings fresh on every run, and
  the set has no version number, so the README note stands in for a version
  bump.

## Before and after

Three fresh MeetingsEval runs on main a8ab25e7 (STT-3.7, notes on gpt-6-luna
medium), with M5 judged by Fable exactly as for gate (a):

| Meeting | Gate (a) M5, 3 runs | After, 3 runs | Mean |
|---|---|---|---|
| s3-four-people | 83 / 84 / 85 = 84.0 | 88 / 94 / 95 = 92.3 | passes 85 |
| s4-names-unsaid-echo (data unchanged) | 60 / 60 / 60 = 60.0 | 95 / 60 / 80 = 78.3 | fails |

- **s3-four-people:** Rahul's line now transcribes correctly in all 3 runs,
  and his Spanish-segment action is listed with him as owner in 3 of 3 runs.
  It was missing in all 11 earlier packets. M1–M4 are the same in all 3
  runs: 100 / 97.5 / 95.7 / 91.8.
- **s4-names-unsaid-echo:** all three transcripts read "You'll set numbers by
  Friday then", so the spread comes from the notes model reading that
  sentence differently each time. Some runs invent a Friday "set the numbers"
  item, owned by Dana or by no one. This remains an AssemblyAI weakness on
  clean audio. A possible notes rule, untested: a date restated in a closing
  recap belongs to an action already agreed and never creates a new one.

Gate (a) stays closed on the decision recorded in #140. This doesn't block
0.7.19. Cost: about $0.06 of AssemblyAI and LLM Gateway calls for the 6
meeting runs.
