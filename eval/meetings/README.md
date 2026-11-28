# Meetings evaluator

Runs recorded-style meetings through VoiceiQ's own meeting code and writes
what the app would show, one JSON per meeting, for a scorer to compare with
the reference. It uses the same steps `MeetingEngine` runs after a recording
stops:

1. `MeetingTranscriber` transcribes with AssemblyAI STT-3.7 and lets the on-device
   speaker model (pyannote community-1) decide who on the far side said what.
2. `ScreenSpeakerNames.match` names speakers from the call window's names.
   `ScreenSpeakerNames.byAddress` then names a voice that answers right
   after someone addresses an invitee or on-screen name ("Nihal, can you…"),
   before the notes are written.
3. `MeetingNotesPrompt` writes the notes, and `ScreenSpeakerNames.byElimination`
   names the last unnamed voice from the calendar.
4. Speakers are named as the meeting screen names them
   (`MeetingMeta.displayName`). The note owner, shown as "You" in the app,
   is written with their name.

Nothing here holds a key or a recording. `prepare.py` downloads AMI at run
time and renders the synthetic meetings with macOS voices.

## Run

On a Mac with Xcode, ffmpeg and python3:

```sh
cd eval/meetings
python3 prepare.py ~/evaldata                  # AMI ES2004a + synthetic meetings
ASSEMBLYAI_API_KEY=… swift run -c release MeetingsEval ~/evaldata ~/evalout
```

`MeetingsEval DATA OUT [meeting-id …]` runs only the meetings named.
`EVAL_NO_SPEAKER_MODEL=1` runs without the on-device speaker model.
An account without an LLM Gateway balance gets transcripts but no notes,
so M2–M4 score and M1 counts only names from the call window.
MeetingsEval keeps its own files in `~/Library/Application Support/VoiceiQ-MeetingsEval`,
never in the app's data folder: the speaker model (21.6 MB, downloaded on the first run)
and `transport.jsonl`, the log of every request attempt.

## On device, and Hex's offline pass

`LocalMeetingsEval` transcribes the same prepared meetings with no cloud
call, for comparing the on-device meeting path with other ways of doing it.
It writes one folder of outputs per pipeline:

| Folder | Pipeline |
|---|---|
| `voiceiq-pro`, `voiceiq-mini` | No longer written: the app transcribed meetings on device (`LocalMeetingTranscriber`) until #118 removed that path. Earlier runs decoded each track whole by Fluid Speech Pro or Mini and split the far side by pyannote community-1. |
| `voiceiq-unified` | The same steps written out in the evaluator with the speech model swapped for the one Hex ships, Parakeet Unified English 0.6B (FluidAudio's Core ML build, `EVAL_MODEL=unified`). The app has no such model. It writes nothing for a meeting whose mic is not echo-free (TS3003a), where the app falls back to one mixed track, so a comparison that includes it covers five meetings. |
| `hex-pro`, `hex-mini`, `hex-unified` | Hex's offline pass, ported in `HexStyle.swift`, with the same speech model: chunks cut at pauses (6 to 10 s), a speech detector before the model, microphone lines that echo the far side dropped. Two speakers, as Hex writes them: the owner and "Them". |
| `hex-speakers-*` | The same words with the far side split by VoiceiQ's speaker model, which hears the far track raised as it does in the app, and joined into turns as the app does. `hex-speakers-noecho-*` drops no microphone line. |

```sh
python3 prepare.py ~/evaldata --no-synthetic --ami ES2004a ES2004b ES2004c ES2004d IS1009a TS3003a
swift build -c release -Xswiftc -enable-testing --product LocalMeetingsEval   # calls the app's internal steps
"$(swift build -c release -Xswiftc -enable-testing --show-bin-path)/LocalMeetingsEval" ~/evaldata ~/evalout   # EVAL_MODEL=mini or unified for the other models
```

`hex_upstream.py` runs upstream Hex itself (a debug build, its own model and
speech detector) on the same folders, and `hex_upstream_speakers.py` gives
its far-side lines to the people VoiceiQ's speaker model heard:

```sh
python3 hex_upstream.py ~/hex/target/debug/hex ~/hexdata ~/evaldata ~/evalout/hex-upstream
python3 hex_upstream_speakers.py ~/evalout/hex-upstream ~/evalout/far-speakers ~/evalout/hex-upstream-speakers
```

`compare.py DATA_DIR PIPELINE_DIR …` prints M1–M4, plain WER and run time
(`seconds.transcribe`; for `voiceiq-*` it includes reading the call audio and
cancelling the mic's echo, also given alone as `seconds.call_audio`)
for each pipeline, pooled and per meeting; `--drop-unmatched` scores them
again without the speakers matched to nobody, and `unmatched.py DATA_DIR
PIPELINE_DIR` says who those speakers are. `wer.py` is the plain WER alone:
words against words on each track, speakers ignored, which M4 (cpWER) cannot
show because it also charges every word given to the wrong person.

AMI is a room, not a call: every headset also hears the other three people.
`leak.py DATA_DIR` measures it while each person talks alone. On the six
meetings used on 2026-11-27 the owner's mic hears the loudest other person 2
to 22 dB below the owner. The far side hears the owner as loudly as its own
people in ES2004a, and 5 to 26 dB below them in the other five. A real call's
far side never carries the owner. So AMI is a hard test of echo handling, and
the owner's voice on the far side costs every pipeline an extra far-side
speaker in most meetings.

`EVAL_ECHO_REPLAY=REPORT LocalMeetingsEval DATA OUT MEETING` checks the echo
port against Hex itself: REPORT is the output of Hex's
`hex meeting echo DIR --transcribe` for that meeting, with each line's end
time printed after its start time (a one-line change to Hex's report).

## Meetings

| Folder | What it tests |
|---|---|
| `ami-ES2004a` | AMI ES2004a (CC BY 4.0), 17.5 min, four people. The speaker who talks most is the mic; the other three headsets summed are the far side. People are named by their AMI role ("Project Manager"), as the abstractive summary names them, and the owner's role is passed as the owner's name. No calendar. |
| `s1-one-to-one` | Two people on Zoom, gallery view, one invitee. |
| `s2-three-people` | Three people on Meet in Chrome: one single-word name (Nihal), two male voices, as on 2026-11-23. |
| `s3-four-people` | Four people on Teams, names said in passing. |
| `s4-names-unsaid` | Three people on a Slack huddle with no window names; one person never says their name and is named only by the calendar. |
| `*-echo` | The same meeting with the far side leaking into the mic through the speakers (60 ms late, a third of its level). |

Run `prepare.py` from Terminal.app, not from a background process such as an
Amp runner. Siri neural voices like Aman read files that macOS lets only
Terminal reach, and `say` fails without them. Check every new render: on
2026-11-28 `s3-four-people` was rebuilt because its earlier Aman render had
garbled Rahul's lines (see `activities/2026-11-28-eval-s3-aman-regen.md`).

Each folder holds `mic.caf` and `system.caf` (16 kHz mono, as the app records),
`input.json` (what the app knows: owner, call app, calendar invitees, whether
the call window shows everyone) and `reference.json`.

## Output

`OUT/<id>.json`:

```json
{
  "id": "s2-three-people",
  "segments": [{"start": 0.5, "end": 4.1, "speaker_name": "Cyron Das", "speaker_id": "you", "text": "…"}],
  "participants": ["Cyron Das", "Nihal", "Muhammed Hafeed"],
  "notes": "# Title\n…markdown, as Export writes it…",
  "seconds": {"transcribe": 21.4, "notes": 5.2}
}
```

`reference.json` has `participants` (names, or null for AMI), `segments`
(`start`, `end`, `speaker`, `text`), `summary` (AMI's abstractive summary, or
the script's decisions and action items), and for synthetic meetings
`decisions` and `actions` with owners.

## Cost

Every AssemblyAI call a meeting makes is metered the way the app meters it
(`UsageMeter`), priced by `PriceBook` **at January 2027 prices** (2027-01-02), and written to the output (values illustrative):

```json
"usage": [{"stage": "meetingSummary", "model": "gemini-3.8-flash", "text_in": 2001,
           "audio_in": 0, "image_in": 0, "cached_in": 1500, "text_out": 410,
           "audio_out": 0, "thought_out": 0, "estimated": false, "cost_usd": 0.0064}],
"duration_seconds": 1049.2, "transcribe_cost_usd": 0.41, "notes_cost_usd": 0.012,
"cost_usd": 0.42, "cost_usd_per_hour": 1.44
```

`transcribe_cost_usd`, `cost_usd` and `cost_usd_per_hour` are left out under
`EVAL_TRANSCRIPTS` (no transcription ran), and any total is left out when a
call had no price. A notes prompt is a fixed cost, so a 70-second call's per-hour
figure is meaningless; take the meeting-hour cost (scorecard C1) from long
meetings such as AMI.
