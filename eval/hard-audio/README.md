# Hard real-audio eval: send without reading

Scores how often a dictation could be sent without reading it, on recordings
of real people: accented, noisy, far-field, whispered and Tamil speech. The
clips come from public corpora with human transcripts. Scorecard item D7
(`eval/SCORECARD.md`). Findings and proposed fixes are in
`activities/2026-11-26-hard-audio-eval.md`.

Audio, references and results stay out of git: two sources are CC BY-NC, and
none of them may be redistributed here without attribution work. Everything
is rebuilt from the sources below into `.amp/in/orb-backup/hard/` (override
with `HARD_AUDIO_DATA`).

## Set (451 clips, 1.5 h)

| Stratum | Clips | Source | Licence |
| --- | --- | --- | --- |
| `va_dictation` | 151 | Voice Arena Dictation Dataset, public test: US English dictations with spoken and intended references | CC BY-NC 4.0 |
| `monsoon_ta` | 60 | Monsoon en-IN (Voice Arena), speakers native to Tamil Nadu, own phones, spontaneous | CC BY 4.0 |
| `monsoon_in` | 60 | Monsoon en-IN, speakers from other Indian states | CC BY 4.0 |
| `indicvoices_ta` | 50 | IndicVoices Tamil (AI4Bharat), via the tinisoft validation-subset mirror: conversational Tamil with English words | CC BY 4.0 |
| `svarah` | 40 | Svarah (AI4Bharat), Indian English, via the amrithanandini mirror | CC BY 4.0 |
| `edacc` | 32 | EdAcc (Edinburgh): Indian, Nigerian, Kenyan, Ghanaian, Jamaican, Spanish, Vietnamese, Chinese, Italian, Irish and other English accents, conversational | CC BY-SA 4.0 |
| `whisper` | 28 | EARS and Expresso whispered speech, some with two background talkers at 10% or 25% volume | CC BY-NC 4.0 |
| `chime6` | 30 | CHiME-6 dev, one far-field Kinect channel in a dinner-party room | CC BY 4.0 |

The NC sets are used only for this private evaluation; VoiceiQ is free and
non-commercial. Hindi and Hindi-English data are left out on purpose: the
owner dictates in English and Tamil.

Selection: 4–30 s and 8+ words (IndicVoices 6+ words; EdAcc 3–30 s, 10+ words; CHiME-6 3–15 s, 7+
words with at most 0.5 s of another talker), one clip per speaker where the
corpus allows. Conversational corpora are cut from longer talk, so some clips
start or end mid-sentence; read the per-stratum numbers with that in mind.

## Scoring

The method is Voice Arena's Dictation Bench (ZER and AMEND, judge prompt from
`github.com/VoiceArenaAI/AMEND`, Apache-2.0). A judge model receives the
verbatim SPOKEN reference, the INTENDED text and the draft, and returns the
draft with the fewest edits it needs. Code counts the character edits after
AMEND's normalisation.

- **send-ready**: no content edit and no form problem (a question written as
  a statement, a mangled list or email, wrong script, artifacts). This is D7.
- **ZER**: no content edit, Voice Arena's headline metric.
- **AMEND**: pooled character edit rate.

Corpus clips have only a verbatim transcript. `judge.py --intended` writes
their INTENDED text once from it (fillers and restarts removed, nothing else)
and caches it, so every run is judged against the same reference.

## Commands

```sh
python3 eval/hard-audio/fetch.py && python3 eval/hard-audio/monsoon_more.py && python3 eval/hard-audio/chime6.py   # clips + manifest; see chime6.py for its download
eval/promptdump/build.sh
GEMINI_API_KEY=... python3 eval/hard-audio/run.py LABEL          # Gemini audio, every option on
GEMINI_API_KEY=... python3 eval/hard-audio/run.py LABEL --ondevice ondevice_pro.json   # on-device transcript, Gemini writes
OPENAI_API_KEY=... GEMINI_API_KEY=... python3 eval/hard-audio/judge.py --intended
python3 eval/hard-audio/judge.py eval/hard-audio/results/LABEL.json --misses
python3 eval/hard-audio/wer.py eval/hard-audio/results/LABEL.json   # free: WER against the references
```

On a Mac, the on-device transcripts (Fluid Speech Pro or Mini, loaded the way
`ParakeetSession` loads them, without the English tools' rescoring):

```sh
(cd eval/hard-audio/ondevice && swift build -c release && mkdir -p out &&
  .build/release/OnDeviceEval <model dir> <clips dir> <ids file> out/ondevice_pro.json)
python3 eval/hard-audio/wer.py --ondevice eval/hard-audio/ondevice/out/ondevice_pro.json
```

Judge calls are cached in the data folder per prompt, so judging the same
draft again costs nothing. **Every `run.py` and `judge.py` call is a paid
API call.** One Gemini pass over the set costs about ₹210; GPT-6 Astra judging
of one pass costs about $25–35. Get the owner's go-ahead first.
