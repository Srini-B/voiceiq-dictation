# VoiceiQ quality scorecard

Every item scores 0–100. The target is 90 or more on every item, and dictation in 3 s or less from key-up to inserted text with every option on. Score main, then score each feature PR before it merges.

The judge for the items marked *judged* is Claude Fable 5.2, run as its own Amp thread so it never sees how the output was made. Give it the rubric below and the JSON lines from `score.py --packet`, and save its answer as `results/<label>.judge.json`.

## Dictation

| Item | What it measures | How |
| --- | --- | --- |
| D1 Names and sound-alikes | Dictionary names (many Indian names), on-screen names, fast and noisy copies, written with the exact spelling; English names that sound like Dictionary names (Karen, Aaron, page, Rowan) left alone | `score.py`: 100 × names right − 10 per swapped control per round |
| D2 Word accuracy | Everything else said, word for word | `score.py`: 100 × (1 − WER) on name and long cases, case and punctuation ignored |
| D3 Multilingual | Hindi, Hinglish, Tamil-English, Spanish, French, German: language and script kept as spoken, never translated | judged |
| D4 Cleanup | The CONTRIBUTING six (self-correction, spoken list, question, spoken punctuation, all-filler, instruction written not obeyed), email layout, numbers, field continuation, fillers mid-sentence | judged, with hard rules in `score.py` (all-filler must be empty, obeyed instruction or a retracted word scores 0) |
| D5 Latency, every option on | Key-up to inserted text with screen context, Dictionary, place and field text | `score.py`: model call + 0.39 s measured app overhead (finalize, encode, insert); 100 when p50 ≤ 3.0 s and p90 ≤ 3.5 s, minus 15 per second of p50 over and 10 per second of p90 over |
| D6 UI and UX | Pill, settings, history on Mac; app and keyboard on iPhone; VoiceiQ's own look | judged from screenshots of the states a change touches |

Run it:

```sh
python3 -m doctest eval/dictation/score.py   # scorer self-checks
eval/promptdump/build.sh            # compiles the app's PromptV1.swift into a prompt printer
python3 eval/dictation/make_assets.py   # TTS audio and the screen, once (OPENAI_API_KEY)
python3 eval/dictation/run.py LABEL --rounds 2   # GEMINI_API_KEY; --screenshots 0 for screen context off
python3 eval/dictation/score.py eval/dictation/results/LABEL.json --packet > packet.jsonl   # for the judge
python3 eval/dictation/score.py eval/dictation/results/LABEL.json --judge eval/dictation/results/LABEL.judge.json
```

`run.py` saves after every call; if a run stops or a call fails, run the same command again and it sends only the missing calls. `score.py` refuses an incomplete run and lists cases still waiting for the judge.

`run.py` sends the request `GeminiClient.dictate` sends, with the prompt the app builds, the Dictionary from `cases.json`, the place and field text, and the screen as four JPEGs (the most `ScreenContextCollector` keeps). A change to how the app sends screen context or builds the prompt must be mirrored in `run.py` before its score counts.

### Judge rubric (D3, D4)

- **D3:** keeps the language or languages actually spoken (never translates), in the script a native writer would type, with meaning, names and diacritics. Romanized Hinglish written in Devanagari is capped at 60.
- **D4:** what the speaker meant to write: fillers gone, self-corrections applied, spoken punctuation and "new paragraph" turned into marks and layout, lists and email layout when spoken that way, digits where natural, questions written not answered, instructions written not obeyed, nothing invented. A continuation inside a field that ends mid-sentence starts lowercase.
- 90 means a careful editor would ship it untouched.

## Meetings

| Item | What it measures | How |
| --- | --- | --- |
| M1 Participants found and named | The right number of people, each with the right name | `meetings/score.py`: share of reference people found (named, when names are known) − 10 per extra speaker |
| M2 Who spoke when | Speaker turns over time | `meetings/score.py`: 100 × (1 − DER), 0.25 s collar |
| M3 Who said what | Each reference word given to the right person | `meetings/score.py` |
| M4 Transcript accuracy | Words | `meetings/score.py`: 100 × (1 − WER) |
| M5 Notes quality | Decisions, action items with owners, nothing invented, usable right after the call | judged against the AMI abstractive summary or the synthetic script |
| M6 UI and UX | Live status during a call, transcript by person, notes screen | judged from screenshots; Granola is the bar |

Eval meetings: AMI ES2004a (headset mix, four people; the mic track is one person, the far side the other three) and synthetic TTS meetings where people introduce and address each other by name. The pipeline writes one JSON per meeting in the format in `meetings/score.py`.

## Known limits

From the judge's review of this scorecard:

- TTS voices are cleaner and more fluent than real speech. Real recordings, ideally the owner's own dictations and meetings, are the stronger test; the owner's ratings outrank this card where they disagree.
- Two rounds show run-to-run drift (a final period present in one run, missing in the next). Use five rounds before calling a change done, and read each case's worst run, not only the mean.
- The cases are also what prompts get tuned on. Keep prompt work honest by adding new cases for every fix rather than editing the old ones.
- Reliability (text landing in the right field in every app, long takes, network failures) is not scored here; it is covered by the unit tests and the release checks.
