# Meetings evaluator

Runs recorded-style meetings through VoiceiQ's own meeting code and writes
what the app would show, one JSON per meeting, for a scorer to compare with
the reference. It uses the same steps `MeetingEngine` runs after a recording
stops:

1. `MeetingTranscriber` transcribes with Gemini and lets the on-device
   speaker model (pyannote community-1) decide who on the far side said what.
2. `ScreenSpeakerNames.match` names speakers from the call window's names.
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
GEMINI_API_KEY=… swift run -c release MeetingsEval ~/evaldata ~/evalout
```

`MeetingsEval DATA OUT [meeting-id …]` runs only the meetings named.
`EVAL_NO_SPEAKER_MODEL=1` runs without the on-device speaker model.
The first run downloads the speaker model (21.6 MB) into the app's model folder.

## Meetings

| Folder | What it tests |
|---|---|
| `ami-ES2004a` | AMI ES2004a (CC BY 4.0), 17.5 min, four people. The speaker who talks most is the mic; the other three headsets summed are the far side. No names, no calendar. |
| `s1-one-to-one` | Two people on Zoom, gallery view, one invitee. |
| `s2-three-people` | Three people on Meet in Chrome: one single-word name (Nihal), two male voices, as on 2026-11-23. |
| `s3-four-people` | Four people on Teams, names said in passing. |
| `s4-names-unsaid` | Three people on a Slack huddle with no window names; one person never says their name and is named only by the calendar. |
| `*-echo` | The same meeting with the far side leaking into the mic through the speakers (60 ms late, a third of its level). |

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

Every Gemini call a meeting makes is metered the way the app meters it
(`UsageMeter`, priced by `PriceBook`), and written to the output as `usage`:
stage, model, input tokens by modality (`text_in`, `audio_in`, `image_in`),
`cached_in`, `text_out`, `audio_out`, `thought_out`, and `cost_usd`. The output
also has `duration_seconds` (the longer of the two tracks), `cost_usd` and
`cost_usd_per_hour`. With `EVAL_TRANSCRIPTS` set, transcription is skipped, so
only the notes calls are counted.
