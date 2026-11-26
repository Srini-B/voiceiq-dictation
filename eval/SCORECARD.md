# VoiceiQ quality scorecard

Every item scores 0–100. The target is 90 or more on every item, dictation in 3 s or less from key-up to inserted text with every option on, and Gemini cost under ₹250 a month at the owner's pace for dictation and meetings together, at the highest announced prices. Score main, then score each feature PR before it merges. A change that adds Gemini calls or tokens (a backup request, sending on a pause, another meeting call) shows its C1 before it ships.

**Who scores.** Claude Fable 5.2 is the scorer of record, run as its own Amp thread so it never sees how the output was made.
- Items marked *judged* get the rubric for that item and their inputs:
  - D3 and D4: the JSON lines from `dictation/score.py --packet`. Ask for one JSON object mapping each packet `key` to an integer 0–100, and save it as `dictation/results/<label>.judge.json`; `score.py --judge` reads it and lists any keys still missing.
  - M5: the notes and reference from `meetings/score.py --packet`, plus each synthetic meeting's script, so nothing invented passes unchecked.
  - D6, K1 and M6: screenshots of every state the change touches, light and dark, each beside the system equivalent where one exists.
  - Ask for an integer score per case or meeting and one line for each score under 90.
- Measured items (names, word accuracy, latency, M1–M4): the scripts compute the numbers; send Fable the report with its misses, and the score counts once Fable accepts it or corrects it.

**Second review.** Gemini Neon, through the Antigravity CLI, reviews each PR, and main before each release. Weigh its review with Fable's scores before merging or releasing. A finding it raises that Fable's scores don't reflect gets fixed or answered in the PR before the merge.

## Dictation

| Item | What it measures | How |
| --- | --- | --- |
| D1 Names and sound-alikes | Dictionary names (many Indian names), on-screen names, fast and noisy copies, written with the exact spelling; English names that sound like Dictionary names (Karen, Aaron, page, Rowan) left alone | `score.py`: 100 × names right − 10 per swapped control per round |
| D2 Word accuracy | Everything else said, word for word | `score.py`: 100 × (1 − WER) on name and long cases, case and punctuation ignored |
| D3 Multilingual | Hindi, Hinglish, Tamil-English, Spanish, French, German: language and script kept as spoken, never translated | judged |
| D4 Cleanup | The CONTRIBUTING six (self-correction, spoken list, question, spoken punctuation, all-filler, instruction written not obeyed), email layout, numbers, field continuation, fillers mid-sentence | judged, with hard rules in `score.py`: all-filler must be empty; a listed `must_not` word in the output (an obeyed instruction's content, a retracted word) scores 0; a missing `must_end` mark caps the case at 50 |
| K1 iPhone keyboard typing | Layout and typing parity with the iOS system keyboard | judged from screenshots beside the system keyboard on the same simulator |
| D5 Latency, every option on | Key-up to inserted text with screen context, Dictionary, place and field text | `score.py`: model call + 0.39 s measured app overhead (finalize, encode, insert); 100 when p50 ≤ 3.0 s and p90 ≤ 3.5 s, minus 15 per second of p50 over and 10 per second of p90 over |
| D6 UI and UX | Pill, settings, history on Mac; app and keyboard on iPhone; VoiceiQ's own look | judged from screenshots of the states a change touches |

Run it:

```sh
python3 -m doctest eval/dictation/score.py   # scorer self-checks
eval/promptdump/build.sh            # compiles the app's PromptV1.swift into a prompt printer
python3 eval/dictation/make_assets.py   # TTS audio and the screen, once (OPENAI_API_KEY)
(cd eval/dictation && python3 check_assets.py)   # each clip really says its text
python3 eval/dictation/run.py LABEL --rounds 2   # GEMINI_API_KEY; --screenshots 0 for screen context off
python3 eval/dictation/score.py eval/dictation/results/LABEL.json --packet > packet.jsonl   # for the judge
python3 eval/dictation/score.py eval/dictation/results/LABEL.json --judge eval/dictation/results/LABEL.judge.json
```

`run.py` saves after every call; if a run stops or a call fails, run the same command again and it sends only the missing calls. `score.py` refuses an incomplete run and lists cases still waiting for the judge.

`run.py` sends the request `GeminiClient.dictate` sends, with the prompt the app builds, the Dictionary from `cases.json`, the place and field text, and the screen's text in the prompt (the window title and the lines in `cases.json`, an ideal OCR read of one window, where the app sends Vision OCR of the frontmost window, which can lose accents or add window chrome; no image is sent). A change to how the app sends screen context or builds the prompt must be mirrored in `run.py` before its score counts. Like the app, it strips answer artifacts (`ValidationGate.stripArtifacts`) and sends an empty answer once more. Known differences from the app: the app's backup request (`DictationHedge`) is not sent, so D5 is measured without it; a 429 wait counts as latency, as the user would feel it; the 0.39 s app overhead is the 2026-11-18 measurement, not measured per run. `cases.json` sets the English (India) spelling line, the owner's system locale.

D5 of record is pooled: the same commit run at least 5 times spread across a day, with p50 and p90 taken over all calls together and each run's score reported beside the pooled one. To credit a commit with a speed change, interleave its runs with main's in the same session so both see the same Gemini load.

### Judge rubric

- **D3:** keeps the language or languages actually spoken (never translates), in the script a native writer would type, with meaning, names and diacritics. Romanized Hinglish written in Devanagari is capped at 60.
- **D4** (the cleanup cases, and the long dictations too): what the speaker meant to write: fillers gone, self-corrections applied, spoken punctuation and "new paragraph" turned into marks and layout, lists and email layout when spoken that way, digits where natural, questions written not answered, instructions written not obeyed, nothing invented. A continuation inside a field that ends mid-sentence starts lowercase. A dropped spoken clause caps that case at 70.
- **M5:** decisions stated correctly; every owned commitment in the action list with its owner and date (a wrong owner costs more than a missing item); nothing invented (an invented commitment by a named person scores 0); length fits the call.
- **D6, K1, M6:** clear, legible controls at full contrast; one consistent look across devices and modes; parity with the system control it stands in for; VoiceiQ's own identity, not a clone.
- 90 means a careful editor would ship it untouched, or the owner would choose it over the alternative (the system keyboard, Granola) every day.

## Meetings

| Item | What it measures | How |
| --- | --- | --- |
| M1 Participants found and named | The right number of people, each with the right name | `meetings/score.py`: share of reference people found (named, when names are known) − 10 per extra speaker |
| M2 Who spoke when | Speaker turns over time | `meetings/score.py`: 100 × (1 − DER), 0.25 s collar |
| M3 Who said what | Each reference word given to the right person | `meetings/score.py` |
| M4 Transcript accuracy | Words, in order, per person | `meetings/score.py`: 100 × (1 − cpWER), the CHiME meeting WER: each person's words against the words given to them |
| M5 Notes quality | Decisions, action items with owners, nothing invented, usable right after the call | judged against the AMI abstractive summary or the synthetic script |
| M6 UI and UX | Live status during a call, transcript by person, notes screen | judged from screenshots; Granola is the bar |

Eval meetings: AMI ES2004a (headset mix, four people; the mic track is one person, the far side the other three) and synthetic TTS meetings where people introduce and address each other by name. The pipeline writes one JSON per meeting in the format in `meetings/score.py`. Score all eval meetings in one call (`score.py OUT1 REF1 OUT2 REF2 …`): the `pooled` scores are the scores of record. M1 is the mean of the per-meeting M1 scores; M2–M4 pool error time over speech time and word errors over reference words, so the long real meeting weighs by its length and short synthetic calls can't outvote it.

## Cost

| Item | What it measures | How |
| --- | --- | --- |
| C1 Gemini cost per month | Dictation and meetings together at the owner's pace (`cost.json` profile `owner`), at the highest announced prices | `cost.py`: each eval call's tokens at `cost.json`'s prices (each extra request Gemini bills pays one more call), times dictations a month, plus meeting hours a month times the per-hour cost; 100 at or under ₹200, 90 at ₹250, minus 1 per 1% over ₹250 |

```sh
python3 -m doctest eval/cost.py
python3 eval/cost.py eval/dictation/results/LABEL.json   # default: 2027-01 prices (the highest announced); --prices 2026-12 for the 2026 prices
# a run from a runner that does not send the backup request needs the share the app sends it on:
python3 eval/cost.py eval/dictation/results/LABEL.json --backup-share 0.08
```

Every release reports cost per dictation and per meeting hour beside C1, with the typical profile (600 dictations and 10 meeting hours) as a check and the heavy profile reported but not gated. Gemini is the default for dictation, writing and meetings. On device is used only in rare cases (about 5% of use at most), only where it clearly helps and scores 90 or more, and never to meet the budget: cost comes down through caching, shorter prompts and fewer extra calls. The backup request and any early send-on-pause request share a cap of about 10% extra dictation calls. `cost.py` prices only a complete run whose runner sent the app's backup request (each result records `usage.secondRequests`); for an older run, `--backup-share` gives the share measured from the app. `cost.json` records where its prices, exchange rate and profiles come from. Meetings use a per-hour figure from the cost study until the meeting pipeline records its own token usage.

## Known limits

From the judge's review of this scorecard:

- TTS voices are cleaner and more fluent than real speech. Real recordings, ideally the owner's own dictations and meetings, are the stronger test; the owner's ratings outrank this card where they disagree.
- Two rounds show run-to-run drift (a final period present in one run, missing in the next). Use five rounds before calling a change done, and read each case's worst run, not only the mean.
- The cases are also what prompts get tuned on. Keep prompt work honest by adding new cases for every fix rather than editing the old ones.
- Reliability (text landing in the right field in every app, long takes, network failures) is not scored here; it is covered by the unit tests and the release checks.
