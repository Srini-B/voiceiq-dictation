# 2026-11-27: Hex's offline meetings against VoiceiQ's on-device meetings

## Why

cyron: "If how Hex does the meeting offline is better, we can also provide
that option, as long as we do the testing with some real meeting audios and a
review round with Neon and Fable." Hex (github.com/anomalyco/hex, MIT)
shipped on-device meetings. VoiceiQ already has an on-device meeting source
(`meetingSource == .onDevice`). This entry records the measurement and the
decision.

The bar is cyron's and `eval/SCORECARD.md`'s. Offline may ship only as an
option beside Gemini, never the default, and only where it scores 90 or more
on M1 to M4.

## Verdict

Don't ship a Hex-style offline option. No app code changes.

1. Hex cannot tell the remote people apart. It writes two speakers, the
   owner and "Them". Its naming from the call window (commits 2609852c,
   0d4b2758, 4ef808b7) is not connected to the transcript yet. On these
   four-person meetings Hex itself scores 50.0 on M1 and 13.2 on M4.
2. The parts of Hex that differ from VoiceiQ are how it cuts each track into
   6 to 10 s chunks at pauses and how it drops microphone lines that echo the
   far side. Running those with VoiceiQ's models and VoiceiQ's speaker split
   does not beat VoiceiQ as it is: M1 91.7 against 87.5, M2 47.2 against
   45.7, M3 69.3 against 69.6, M4 49.9 against 57.3.
3. The best offline result measured is Hex's own build for the words and
   VoiceiQ's speaker model for the people: 91.7 / 52.4 / 74.1 / 63.2. That is
   38 points under the bar on M2. It also needs Hex's own speech runtime. A
   Swift port with the same model family did not reproduce its words (plain
   WER 39.6 against 32.3 on five meetings, cause not found).
4. Nothing offline reaches 90 on M2, M3 or M4. VoiceiQ on device as it is
   scores 87.5 / 45.7 / 69.6 / 57.3.
5. On ES2004a, the one meeting with recorded Gemini scores, Gemini has
   100.0 / 84.7 / 81.9 / 79.2. The best offline result has
   90.0 / 57.9 / 79.3 / 73.8 and VoiceiQ on device has
   90.0 / 34.6 / 68.4 / 55.3.

Gemini's recorded scores on AMI alone are also under 90 on M2 to M4. The 90
gate of record pools AMI with synthetic meetings, which this decision
excludes. So the gate alone is harsher here than on the scorecard. The
verdict does not rest on the gate alone: on the same meeting every offline
pipeline is under Gemini on every item.

## Meetings

Six AMI meetings with human transcripts, 171.6 minutes and about 27,000
reference words. `prepare.py` set each up as a call: one person's headset is
the mic, the other three headsets summed are the far side.

| Meeting | Minutes | Reference words | Mic owner | Owner's share of words |
| --- | --- | --- | --- | --- |
| ES2004a | 17.5 | 2,614 | Speaker B | 41% |
| ES2004b | 39.1 | 6,763 | Speaker D | 30% |
| ES2004c | 38.9 | 6,968 | Speaker C | 33% |
| ES2004d | 37.0 | 6,134 | Speaker D | 36% |
| IS1009a | 14.0 | 1,986 | Speaker A | 60% |
| TS3003a | 25.1 | 2,518 | Speaker A | 79% |

No synthetic audio. No Gemini call and no OpenRouter call was made, so the
spend is $0. OpenRouter lists no `gemini-3.5-transcribe`, only Gemini chat
models, so a run there would not have measured what VoiceiQ uses.

## Pipelines

All ran on an Amp Mac satellite (macos-27, Apple M4 Pro virtual machine, 6
cores, Xcode 27.3), from VoiceiQ at cfb7a15 and Hex at b67dd262. The Mac mini
runner was not used, as the brief asked.

| Name | What it is |
| --- | --- |
| `voiceiq-pro`, `voiceiq-mini` | The app's own `LocalMeetingTranscriber`, unchanged, with Fluid Speech Pro or Mini and pyannote community-1 for the far side. |
| `hex-pro` | Hex's offline pass ported to Swift (`HexStyle.swift`) with Fluid Speech Pro: pause-cut chunks, a speech detector before the model, echoing mic lines dropped. Two speakers, as Hex writes them. |
| `hex-speakers-pro`, `-mini`, `-unified` | The same words with the far side split by VoiceiQ's speaker model. `unified` uses the model family Hex ships (Parakeet Unified English 0.6B) through FluidAudio's Core ML build. |
| `hex-speakers-noecho-pro` | As `hex-speakers-pro` with no mic line dropped. |
| `hex-upstream` | Hex itself, a build of b67dd262 running `hex meeting transcribe` with its own model and runtime. Two speakers. |
| `hex-upstream-speakers` | Hex's own lines, each far-side line given to the person VoiceiQ's speaker model heard for most of it. |

## Results

Pooled over the six meetings. M1 to M4 are from `score.py`. WER is plain
word error rate per track from `wer.py`, speakers ignored. Lower WER is
better.

| Pipeline | M1 | M2 | M3 | M4 | WER | WER mic | WER far | Run time |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| VoiceiQ on device as it is (`voiceiq-pro`) | 87.5 | 45.7 | 69.6 | 57.3 | 37.2 | 21.5 | 47.6 | 317 s, 32× real time |
| VoiceiQ on device, Mini (`voiceiq-mini`) | 87.5 | 45.8 | 70.3 | 58.2 | 36.6 | 22.1 | 46.3 | 348 s, 30× |
| Hex as it ships, real build (`hex-upstream`) | 50.0 | 31.1 | 49.8 | 13.2 | 35.9 | 27.4 | 41.5 | 2706 s, 4× |
| Hex as it ships, port with Pro (`hex-pro`) | 50.0 | 21.4 | 46.3 | 0 | 49.6 | 49.2 | 49.9 | 339 s, 30× |
| Hex chunks and echo drop, VoiceiQ models and speakers (`hex-speakers-pro`) | 91.7 | 47.2 | 69.3 | 49.9 | 49.6 | 49.2 | 49.9 | 428 s, 24× |
| The same without the echo drop (`hex-speakers-noecho-pro`) | 91.7 | 33.8 | 65.5 | 39.4 | 55.5 | 63.8 | 49.9 | 428 s, 24× |
| The same with Mini (`hex-speakers-mini`) | 91.7 | 50.7 | 70.2 | 54.9 | 44.4 | 38.7 | 48.3 | 475 s, 22× |
| The same with Hex's model family (`hex-speakers-unified`) | 91.7 | 49.4 | 71.7 | 56.5 | 42.7 | 37.9 | 45.9 | 420 s, 25× |
| Hex's real words, VoiceiQ speakers (`hex-upstream-speakers`) | 91.7 | 52.4 | 74.1 | 63.2 | 35.9 | 27.4 | 41.5 | 2706 s, 4× |

ES2004a alone, the meeting Gemini was scored on
(`activities/2026-11-26-meeting-speakers-hybrid.md`):

| Pipeline | M1 | M2 | M3 | M4 | WER |
| --- | --- | --- | --- | --- | --- |
| Gemini, recorded on 2026-11-26, not run again | 100.0 | 84.7 | 81.9 | 79.2 | not measured with `wer.py` |
| VoiceiQ on device as it is | 90.0 | 34.6 | 68.4 | 55.3 | 39.5 |
| Hex as it ships, real build | 50.0 | 41.9 | 62.7 | 36.1 | 21.4 |
| Hex chunks and echo drop, VoiceiQ models and speakers | 90.0 | 53.0 | 71.5 | 63.1 | 32.9 |
| Hex's real words, VoiceiQ speakers | 90.0 | 57.9 | 79.3 | 73.8 | 21.4 |

The earlier entry records Gemini's plain WER on AMI as 33% without fillers.
That figure is above Gemini's own per-person error of 20.8% (M4 79.2), so it
was computed another way and is not compared with `wer.py` here.

The five meetings where the app decodes each track on its own (all but
TS3003a, where the app falls back to one mixed decode because the mic is not
echo-free):

| Pipeline | M1 | M2 | M3 | M4 | WER |
| --- | --- | --- | --- | --- | --- |
| `voiceiq-pro` | 90.0 | 41.7 | 69.2 | 56.1 | 38.3 |
| `voiceiq-unified` (the app's steps, Hex's model family) | 90.0 | 48.0 | 67.9 | 58.0 | 37.3 |
| `hex-speakers-unified` | 90.0 | 54.0 | 73.0 | 60.3 | 39.6 |
| `hex-upstream-speakers` | 90.0 | 57.2 | 75.8 | 67.4 | 32.3 |

Run times are for all six meetings, on a 6-core cloud virtual machine.
`voiceiq-pro` took 343 s and 317 s in two runs and `hex-speakers-pro` 450 s
and 428 s. `hex-upstream` ran once, and its Metal runtime used the virtual
machine's paravirtual GPU, so 4× real time says little about a real Mac.
What limits each run time was not profiled. Run time does not affect the
verdict.

Two full runs of the Pro and Mini pipelines gave the same pooled M1 to M4 to
0.1. Every pipeline wrote an output for every meeting, except
`voiceiq-unified` on TS3003a, which is skipped by design.

## What explains the numbers

**AMI is a room, not a call.** Every headset also hears the other three
people. `leak.py` measures it while each person talks alone. The owner's mic
hears the loudest other person 2 to 22 dB below the owner. The far side hears
the owner as loudly as its own people in ES2004a and 5 to 26 dB below them in
the other five. A real call's far side never carries the owner.

**The fifth speaker is the owner.** Five of six meetings get one speaker
that `score.py` matches to nobody. In `voiceiq-pro` 84 to 98% of
that speaker's time is while the owner talks, and it repeats 485 to 1,756 of
the owner's words per meeting. That costs M1 10 points a meeting and is most
of the far-side WER of 47.6.

**Removing that speaker is not enough.** `compare.py --drop-unmatched` scores
each output again without speakers matched to nobody. `voiceiq-pro` rises to
95.8 / 66.5 / 77.5 / 74.8 with WER 21.6. `hex-upstream-speakers` rises to
100.0 / 57.8 / 76.6 / 70.0 with WER 31.8. Both stay under 90 on M2 to M4.
This reading is an estimate, and an uneven one. It removes the leak cleanly
from VoiceiQ's output, which has word times. Hex gives lines, and a line is
given whole to one person, so leaked words stay inside other people's lines.
In IS1009a under the Hex port, the speaker removed is what is left of the
owner's real mic lines, not the leak.

**Hex's echo drop misfires on a room.** It drops a mic line when delayed,
quieter far-side audio explains its sound. In a room the far side hears the
owner, so the owner's own speech can look like echo. In IS1009a it dropped
148 of the mic's 184 lines and left 258 words under an owner who said 1,188.
The scorer then matched the far side's copy of the owner to the owner, which
is why `hex-speakers-pro` shows M2 68.1 there against 13.5 for `voiceiq-pro`. That gain comes from the room and would
not appear on a call. The port's echo decisions match Hex itself on all 300
mic lines of ES2004b (same signal reading, same keep or drop), so this is
Hex's rule and not a porting error.

**TS3003a breaks every per-track pipeline.** The owner says 79% of the words.
`hex-speakers-pro` writes 1,629 words under a far-side voice whose person
said 60, and far-side WER is 280 to 320% for every Hex variant. The app sees
that the mic is not echo-free (10.4 dB residual), decodes one mixed track
instead, and scores 75.0 / 74.4 / 73.3 / 69.7.

**Hex's own build writes better words on four meetings.** Its plain WER is
lower than `voiceiq-pro` on ES2004a to d (21.4, 22.7, 32.7, 26.4 against
39.5, 30.6, 40.8, 31.5) and higher on IS1009a and TS3003a (95.7 and 71.4
against 74.6 and 26.5). The Swift port with the same model family does not
match it, 39.6 against 32.3 on five meetings. The difference is somewhere in
the speech detector build or the Core ML against GGUF runtime. Which one was
not found.

**The M2 gap to Gemini is not fully explained.** On ES2004a with the leaked
speaker removed, `voiceiq-pro` reads 100.0 / 59.7 / 76.9 / 74.1 against
Gemini's 100.0 / 84.7 / 81.9 / 79.2. M2 is still 25 points behind. The Gemini
path sends only the level-gated regions of the far side
(`activeRegions()`), and the on-device path decodes the whole far track. That
may be why Gemini's fifth voice was 8.7 s in the earlier entry and is 197 s
here. This is a guess from reading the code. It was not measured.

## Scores in Fable's role

The brief asked this thread to score as `eval/SCORECARD.md` describes for
Fable. The scorecard wants Fable in a separate thread that has not seen how
the output was made. This thread made the output, so that independence is
missing. M1 to M4 are measured items: the scripts compute them and the scorer
accepts or corrects them.

| Item | VoiceiQ on device as it is | Hex chunks and echo drop in VoiceiQ | Best offline measured | Bar |
| --- | --- | --- | --- | --- |
| M1 Participants | 87.5 | 91.7 | 91.7 | 90 |
| M2 Who spoke when | 45.7 | 47.2 | 52.4 | 90 |
| M3 Who said what | 69.6 | 69.3 | 74.1 | 90 |
| M4 Transcript accuracy | 57.3 | 49.9 | 63.2 | 90 |

- The script numbers are accepted as computed. No arithmetic was corrected.
- M1 91.7 for the Hex variants is not a real pass. It is over 90 only
  because TS3003a scores 100 on M1 while scoring 6.8 on M2 there: four
  speakers were written, and one of them is the owner's leaked voice
  matched to a person who said 60 words.
- With the room's leaked speaker removed the best reading is
  95.8 / 66.5 / 77.5 / 74.8. Still under the bar on M2, M3 and M4.
- M5 (notes) and M6 (UI) are not scored. The on-device path writes no notes
  without Gemini, and no screen changed.

Result: not clean. Three of four items are under 90 for every offline
pipeline.

## Neon review

Requested on 2026-11-27 from T-01a2176a-eb3e-7024-b1ae-ec9aa9d74f1b. The
verdict is added here when it arrives.

## For the owner thread

No change to the on-device meeting path is asked for. Three observations
for T-01a216c8-4952-74a8-b308-cbc7879e8a45, none of them proven changes:

- On device, the owner's voice leaking onto the far side becomes a whole
  extra speaker (197 s in ES2004a). The Gemini path on the same file kept it
  to 8.7 s. If the on-device path is worth improving, test level-gating the
  far track first. `LocalMeetingsEval` runs it for free.
- The app's fallback to one mixed decode when the mic is not echo-free is
  what saved TS3003a. Keep it.
- AMI cannot judge echo handling for a real call with loudspeakers, which is
  what Hex's echo drop is built for. That needs real two-track call
  recordings with human transcripts. The eval has none.

## Limits

- Gemini's numbers are the recorded ES2004a scores from 2026-11-26. They were
  not scored again here, and they cover one meeting.
- AMI's room leak lowers every offline score. The size of that effect on a
  real call is estimated, not measured.
- Hex was measured at b67dd262. Its later speaker-naming commits are not
  connected to its transcript, so they could not change these scores.
- The Swift port is not identical to Hex outside the echo rules. The rows
  that carry the verdict on Hex's own quality are the `hex-upstream` rows,
  which run Hex itself.
- The runs used VoiceiQ at cfb7a15. Main then moved to 88c042e, and this
  branch sits on that. None of those commits touch `LocalMeeting*`, the
  diarizer or `eval/`. The evaluator built on the rebased branch gives the
  same `voiceiq-pro` scores on ES2004a (90.0 / 34.6 / 68.4 / 55.3).

## Run it again

See "On device, and Hex's offline pass" in `eval/meetings/README.md`. Result
JSON files are not committed. The per-meeting tables below are the record.

## Appendix: every pipeline, per meeting

Run 2 for the Pro and Mini pipelines, the only run for the others.
"Speakers written (matched to nobody)" counts speakers over the meetings
pooled.

### Pooled, six meetings

| Pipeline | M1 | M2 | M3 | M4 | WER | WER mic | WER far | WER, no fillers | Speakers written (matched to nobody) | Run time |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| voiceiq-pro | 87.5 | 45.7 | 69.6 | 57.3 | 37.2 | 21.5 | 47.6 | 36.6 | 28 (5) | 317 s (32× real time) |
| voiceiq-mini | 87.5 | 45.8 | 70.3 | 58.2 | 36.6 | 22.1 | 46.3 | 36.0 | 28 (5) | 348 s (30× real time) |
| hex-pro | 50.0 | 21.4 | 46.3 | 0 | 49.6 | 49.2 | 49.9 | 49.1 | 12 (0) | 339 s (30× real time) |
| hex-speakers-pro | 91.7 | 47.2 | 69.3 | 49.9 | 49.6 | 49.2 | 49.9 | 49.1 | 29 (5) | 428 s (24× real time) |
| hex-speakers-noecho-pro | 91.7 | 33.8 | 65.5 | 39.4 | 55.5 | 63.8 | 49.9 | 55.2 | 29 (5) | 428 s (24× real time) |
| hex-mini | 50.0 | 24.9 | 47.3 | 5.7 | 44.4 | 38.7 | 48.3 | 44.0 | 12 (0) | 381 s (27× real time) |
| hex-speakers-mini | 91.7 | 50.7 | 70.2 | 54.9 | 44.4 | 38.7 | 48.3 | 44.0 | 29 (5) | 475 s (22× real time) |
| hex-unified | 50.0 | 23.5 | 47.7 | 5.9 | 42.7 | 37.9 | 45.9 | 42.2 | 12 (0) | 331 s (31× real time) |
| hex-speakers-unified | 91.7 | 49.4 | 71.7 | 56.5 | 42.7 | 37.9 | 45.9 | 42.2 | 29 (5) | 420 s (25× real time) |
| hex-speakers-noecho-unified | 91.7 | 39.9 | 69.6 | 48.4 | 46.7 | 48.0 | 45.9 | 46.5 | 29 (5) | 420 s (25× real time) |
| hex-upstream | 50.0 | 31.1 | 49.8 | 13.2 | 35.9 | 27.4 | 41.5 | 35.2 | 12 (0) | 2706 s (4× real time) |
| hex-upstream-speakers | 91.7 | 52.4 | 74.1 | 63.2 | 35.9 | 27.4 | 41.5 | 35.2 | 29 (5) | 2706 s (4× real time) |

### ami-ES2004a

| Pipeline | M1 | M2 | M3 | M4 | WER | WER mic | WER far | WER, no fillers | Speakers written (matched to nobody) | Run time |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| voiceiq-pro | 90.0 | 34.6 | 68.4 | 55.3 | 39.5 | 15.6 | 55.8 | 38.8 | 5 (1) | 36 s (29× real time) |
| voiceiq-mini | 90.0 | 36.2 | 71.7 | 58.7 | 36.3 | 16.2 | 50.0 | 36.2 | 5 (1) | 33 s (32× real time) |
| hex-pro | 50.0 | 34.3 | 57.3 | 25.0 | 32.9 | 15.5 | 44.7 | 32.0 | 2 (0) | 33 s (32× real time) |
| hex-speakers-pro | 90.0 | 53.0 | 71.5 | 63.1 | 32.9 | 15.5 | 44.7 | 32.0 | 5 (1) | 40 s (26× real time) |
| hex-speakers-noecho-pro | 90.0 | 52.1 | 71.1 | 61.8 | 34.1 | 18.6 | 44.7 | 33.4 | 5 (1) | 40 s (26× real time) |
| hex-mini | 50.0 | 37.5 | 58.9 | 30.8 | 29.3 | 8.6 | 43.3 | 28.7 | 2 (0) | 36 s (29× real time) |
| hex-speakers-mini | 90.0 | 56.7 | 75.0 | 66.6 | 29.3 | 8.6 | 43.3 | 28.7 | 5 (1) | 43 s (24× real time) |
| hex-unified | 50.0 | 35.0 | 59.2 | 29.3 | 27.9 | 11.8 | 38.8 | 26.8 | 2 (0) | 31 s (34× real time) |
| hex-speakers-unified | 90.0 | 56.0 | 76.7 | 67.4 | 27.9 | 11.8 | 38.8 | 26.8 | 5 (1) | 38 s (27× real time) |
| hex-speakers-noecho-unified | 90.0 | 56.2 | 77.6 | 66.8 | 28.5 | 13.3 | 38.8 | 27.5 | 5 (1) | 38 s (27× real time) |
| hex-upstream | 50.0 | 41.9 | 62.7 | 36.1 | 21.4 | 15.5 | 25.4 | 19.9 | 2 (0) | 238 s (4× real time) |
| hex-upstream-speakers | 90.0 | 57.9 | 79.3 | 73.8 | 21.4 | 15.5 | 25.4 | 19.9 | 5 (1) | 238 s (4× real time) |

### ami-ES2004b

| Pipeline | M1 | M2 | M3 | M4 | WER | WER mic | WER far | WER, no fillers | Speakers written (matched to nobody) | Run time |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| voiceiq-pro | 90.0 | 55.7 | 75.3 | 66.4 | 30.6 | 18.4 | 36.0 | 29.9 | 5 (1) | 78 s (30× real time) |
| voiceiq-mini | 90.0 | 57.7 | 78.6 | 67.5 | 29.4 | 16.8 | 35.0 | 28.6 | 5 (1) | 83 s (28× real time) |
| hex-pro | 50.0 | 13.0 | 43.4 | 0 | 48.1 | 95.9 | 27.0 | 47.7 | 2 (0) | 82 s (28× real time) |
| hex-speakers-pro | 90.0 | 47.2 | 72.8 | 48.8 | 48.1 | 95.9 | 27.0 | 47.7 | 5 (1) | 104 s (23× real time) |
| hex-speakers-noecho-pro | 90.0 | 36.4 | 69.1 | 39.7 | 57.2 | 125.6 | 27.0 | 57.1 | 5 (1) | 104 s (23× real time) |
| hex-mini | 50.0 | 18.2 | 46.5 | 0 | 39.7 | 73.8 | 24.7 | 39.4 | 2 (0) | 94 s (25× real time) |
| hex-speakers-mini | 90.0 | 53.5 | 75.7 | 57.7 | 39.7 | 73.8 | 24.7 | 39.4 | 5 (1) | 115 s (20× real time) |
| hex-unified | 50.0 | 17.3 | 47.5 | 0 | 37.4 | 69.1 | 23.5 | 37.3 | 2 (0) | 78 s (30× real time) |
| hex-speakers-unified | 90.0 | 50.5 | 77.1 | 59.8 | 37.4 | 69.1 | 23.5 | 37.3 | 5 (1) | 99 s (24× real time) |
| hex-speakers-noecho-unified | 90.0 | 43.0 | 73.8 | 52.6 | 44.6 | 92.7 | 23.5 | 44.5 | 5 (1) | 99 s (24× real time) |
| hex-upstream | 50.0 | 32.8 | 52.0 | 9.4 | 22.7 | 32.4 | 18.5 | 22.2 | 2 (0) | 550 s (4× real time) |
| hex-upstream-speakers | 90.0 | 60.8 | 81.8 | 73.8 | 22.7 | 32.4 | 18.5 | 22.2 | 5 (1) | 550 s (4× real time) |

### ami-ES2004c

| Pipeline | M1 | M2 | M3 | M4 | WER | WER mic | WER far | WER, no fillers | Speakers written (matched to nobody) | Run time |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| voiceiq-pro | 90.0 | 37.6 | 66.1 | 52.7 | 40.8 | 23.2 | 49.3 | 40.1 | 5 (1) | 73 s (32× real time) |
| voiceiq-mini | 90.0 | 37.8 | 68.4 | 54.3 | 39.1 | 23.2 | 46.9 | 38.3 | 5 (1) | 79 s (29× real time) |
| hex-pro | 50.0 | 12.5 | 38.3 | 0 | 48.1 | 52.5 | 45.9 | 47.4 | 2 (0) | 75 s (31× real time) |
| hex-speakers-pro | 90.0 | 43.7 | 69.3 | 46.1 | 48.1 | 52.5 | 45.9 | 47.4 | 5 (1) | 99 s (24× real time) |
| hex-speakers-noecho-pro | 90.0 | 41.8 | 68.5 | 44.8 | 49.3 | 56.3 | 45.9 | 48.8 | 5 (1) | 99 s (24× real time) |
| hex-mini | 50.0 | 17.9 | 39.0 | 0 | 40.2 | 29.6 | 45.3 | 39.4 | 2 (0) | 91 s (26× real time) |
| hex-speakers-mini | 90.0 | 49.7 | 70.0 | 54.1 | 40.2 | 29.6 | 45.3 | 39.4 | 5 (1) | 118 s (20× real time) |
| hex-unified | 50.0 | 22.2 | 41.8 | 0 | 37.1 | 26.3 | 42.4 | 36.5 | 2 (0) | 76 s (31× real time) |
| hex-speakers-unified | 90.0 | 53.4 | 72.8 | 57.5 | 37.1 | 26.3 | 42.4 | 36.5 | 5 (1) | 100 s (23× real time) |
| hex-speakers-noecho-unified | 90.0 | 51.8 | 73.1 | 56.4 | 38.2 | 29.5 | 42.4 | 37.5 | 5 (1) | 100 s (23× real time) |
| hex-upstream | 50.0 | 26.5 | 42.2 | 0 | 32.7 | 12.7 | 42.4 | 32.0 | 2 (0) | 620 s (4× real time) |
| hex-upstream-speakers | 90.0 | 54.6 | 74.4 | 61.6 | 32.7 | 12.7 | 42.4 | 32.0 | 5 (1) | 620 s (4× real time) |

### ami-ES2004d

| Pipeline | M1 | M2 | M3 | M4 | WER | WER mic | WER far | WER, no fillers | Speakers written (matched to nobody) | Run time |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| voiceiq-pro | 90.0 | 42.8 | 72.4 | 62.7 | 31.5 | 20.1 | 37.9 | 31.0 | 5 (1) | 64 s (35× real time) |
| voiceiq-mini | 90.0 | 41.5 | 70.7 | 63.6 | 32.1 | 19.2 | 39.2 | 31.7 | 5 (1) | 76 s (29× real time) |
| hex-pro | 50.0 | 37.4 | 51.4 | 14.1 | 30.2 | 26.3 | 32.4 | 29.4 | 2 (0) | 68 s (32× real time) |
| hex-speakers-pro | 90.0 | 65.1 | 73.5 | 64.7 | 30.2 | 26.3 | 32.4 | 29.4 | 5 (1) | 86 s (26× real time) |
| hex-speakers-noecho-pro | 90.0 | 38.0 | 64.7 | 42.5 | 52.4 | 88.7 | 32.4 | 52.1 | 5 (1) | 86 s (26× real time) |
| hex-mini | 50.0 | 38.6 | 51.6 | 19.4 | 29.8 | 24.3 | 32.8 | 29.2 | 2 (0) | 75 s (30× real time) |
| hex-speakers-mini | 90.0 | 64.9 | 72.1 | 65.7 | 29.8 | 24.3 | 32.8 | 29.2 | 5 (1) | 94 s (24× real time) |
| hex-unified | 50.0 | 30.4 | 49.0 | 13.2 | 31.8 | 26.4 | 34.8 | 31.1 | 2 (0) | 69 s (32× real time) |
| hex-speakers-unified | 90.0 | 56.7 | 71.6 | 64.3 | 31.8 | 26.4 | 34.8 | 31.1 | 5 (1) | 86 s (26× real time) |
| hex-speakers-noecho-unified | 90.0 | 35.8 | 65.6 | 44.2 | 51.9 | 82.8 | 34.8 | 51.8 | 5 (1) | 86 s (26× real time) |
| hex-upstream | 50.0 | 37.9 | 50.9 | 19.9 | 26.4 | 23.1 | 28.2 | 25.3 | 2 (0) | 625 s (4× real time) |
| hex-upstream-speakers | 90.0 | 58.5 | 74.1 | 69.9 | 26.4 | 23.1 | 28.2 | 25.3 | 5 (1) | 625 s (4× real time) |

### ami-IS1009a

| Pipeline | M1 | M2 | M3 | M4 | WER | WER mic | WER far | WER, no fillers | Speakers written (matched to nobody) | Run time |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| voiceiq-pro | 90.0 | 13.5 | 50.2 | 13.3 | 74.6 | 29.5 | 141.1 | 75.7 | 5 (1) | 29 s (29× real time) |
| voiceiq-mini | 90.0 | 12.0 | 43.7 | 10.1 | 78.3 | 37.9 | 138.0 | 79.1 | 5 (1) | 35 s (24× real time) |
| hex-pro | 50.0 | 40.2 | 39.9 | 23.7 | 100.8 | 81.8 | 128.9 | 102.9 | 2 (0) | 29 s (29× real time) |
| hex-speakers-pro | 90.0 | 68.1 | 62.5 | 51.8 | 100.8 | 81.8 | 128.9 | 102.9 | 5 (1) | 37 s (23× real time) |
| hex-speakers-noecho-pro | 90.0 | 7.4 | 53.4 | 13.3 | 76.3 | 40.6 | 128.9 | 78.0 | 5 (1) | 37 s (23× real time) |
| hex-mini | 50.0 | 39.5 | 36.9 | 25.6 | 97.1 | 81.2 | 120.4 | 99.0 | 2 (0) | 32 s (26× real time) |
| hex-speakers-mini | 90.0 | 66.5 | 58.6 | 48.3 | 97.1 | 81.2 | 120.4 | 99.0 | 5 (1) | 40 s (21× real time) |
| hex-unified | 50.0 | 30.4 | 36.3 | 25.2 | 94.5 | 84.0 | 110.1 | 96.2 | 2 (0) | 28 s (30× real time) |
| hex-speakers-unified | 90.0 | 58.2 | 59.1 | 49.5 | 94.5 | 84.0 | 110.1 | 96.2 | 5 (1) | 36 s (23× real time) |
| hex-speakers-noecho-unified | 90.0 | 17.3 | 56.5 | 27.9 | 61.0 | 27.7 | 110.1 | 62.2 | 5 (1) | 36 s (23× real time) |
| hex-upstream | 50.0 | 30.4 | 37.2 | 25.7 | 95.7 | 83.1 | 114.3 | 97.4 | 2 (0) | 260 s (3× real time) |
| hex-upstream-speakers | 90.0 | 49.4 | 60.6 | 49.6 | 95.7 | 83.1 | 114.3 | 97.4 | 5 (1) | 260 s (3× real time) |

### ami-TS3003a

| Pipeline | M1 | M2 | M3 | M4 | WER | WER mic | WER far | WER, no fillers | Speakers written (matched to nobody) | Run time |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| voiceiq-pro | 75.0 | 74.4 | 73.3 | 69.7 | 26.5 | 22.6 | 41.4 | 25.3 | 3 (0) | 38 s (40× real time) |
| voiceiq-mini | 75.0 | 73.1 | 72.2 | 69.0 | 27.3 | 23.4 | 42.5 | 26.3 | 3 (0) | 41 s (36× real time) |
| hex-pro | 50.0 | 9.2 | 57.5 | 8.1 | 82.2 | 20.3 | 319.5 | 82.4 | 2 (0) | 51 s (29× real time) |
| hex-speakers-pro | 100.0 | 6.8 | 52.2 | 12.1 | 82.2 | 20.3 | 319.5 | 82.4 | 4 (0) | 62 s (24× real time) |
| hex-speakers-noecho-pro | 100.0 | 6.3 | 53.2 | 13.2 | 81.1 | 18.9 | 319.5 | 81.1 | 4 (0) | 62 s (24× real time) |
| hex-mini | 50.0 | 11.6 | 58.4 | 11.7 | 78.9 | 18.9 | 308.4 | 79.4 | 2 (0) | 54 s (28× real time) |
| hex-speakers-mini | 100.0 | 9.0 | 55.5 | 15.7 | 78.9 | 18.9 | 308.4 | 79.4 | 4 (0) | 65 s (23× real time) |
| hex-unified | 50.0 | 14.9 | 58.5 | 18.0 | 73.2 | 17.7 | 285.8 | 73.6 | 2 (0) | 50 s (30× real time) |
| hex-speakers-unified | 100.0 | 15.9 | 58.8 | 20.2 | 73.2 | 17.7 | 285.8 | 73.6 | 4 (0) | 61 s (25× real time) |
| hex-speakers-noecho-unified | 100.0 | 16.2 | 60.6 | 22.1 | 71.4 | 15.4 | 285.8 | 71.7 | 4 (0) | 61 s (25× real time) |
| hex-upstream | 50.0 | 17.5 | 58.5 | 19.4 | 71.4 | 17.0 | 279.9 | 71.7 | 2 (0) | 413 s (4× real time) |
| hex-upstream-speakers | 100.0 | 17.7 | 58.3 | 22.3 | 71.4 | 17.0 | 279.9 | 71.7 | 4 (0) | 413 s (4× real time) |
