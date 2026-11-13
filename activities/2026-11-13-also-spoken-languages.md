# Also spoken languages that work for whole sentences (2026-11-13, PR #44)

## Why

A maintainer dictated a short Japanese phrase with English as the main
language and Japanese and Tamil under Also spoken. VoiceiQ inserted
English-looking words ("No, Misson, Mata, Astha."). The history row, the log
and a replay of the recording showed the Japanese was lost inside Scribe v3:
the formatting edit and the writing model never saw Japanese (the writing
model was skipped for a dictation under 5 s).

## What was measured (replays of the real 2.6 s recording)

| Request | Text |
| --- | --- |
| `language_code=eng`, secondary `tam`, `jpn` | "No, Missan, Mataasta." / "No, Miss, I'm not hasta." |
| `language_code=eng` only | "No, Miss, I'm not hasta." |
| no language (automatic) | a run of zeros, edit failed |
| `language_code=jpn` (with or without secondary `eng`) | Japanese script |
| Scribe v3 Live, `multilang_mode`, `secondary_languages=eng,jpn` | "Navmisan matha asta." |
| OpenAI gpt-transcribe, `languages[]=en,ja,ta` plus a prompt | "Now miss on Mata Ashta." |

Scribe's batch request has no prompt field; `transcript_edit` edits the
finished text. Mean word logprob (word timestamps) separated the languages:
English -1.08, Japanese -0.22, Tamil -1.45. On the same speaker's real
English dictation (17.9 s and six 3 s cuts) every language returned the same
English and no other language beat English by more than 0.03.

## What changed

- Dictation with two or more spoken languages sends one Scribe v3 request per
  language in parallel and keeps the most confident transcript; the main
  language wins ties within 0.1 (`ElevenLabs.pickCandidate`).
- Menu bar › Spoken Language switches which listed language is main.
- Help text on Mac and iPhone describes the behavior and its cost.
- Prompts: "its mistakes usually still look like English" now says "real words
  in the language being spoken"; "English speech-recognition errors" lost
  "English"; the keep-every-language rule now names scripts and forbids
  romanizing; a Japanese self-correction example joins the examples; the
  Scribe formatting instruction keeps each language in its own script.
- `ValidationGate` counts characters as words in scripts without spaces, and
  treats "？" as a question mark.

## Verification

- End-to-end replay of the new request flow (`eng,tam,jpn`): the real
  Japanese clip and a 1.6 s cut of it pick Japanese; the real English
  dictation and all six cuts pick English; synthetic Japanese, Tamil,
  English and code-switched clips keep their scripts.
- Writing model (gpt-6.1-terra) before and after the prompt change, two runs
  each, on CONTRIBUTING's hand-check cases plus Japanese, Tamil and
  code-switched text: identical results except one Tamil run that joined two
  sentences with a comma. Gemini was not run (no key in the test
  environment).
- Cost: each extra spoken language adds one Scribe transcription and one
  edit per dictation (about $0.0004 for a 3 s dictation, keyterms included).

## Known issue found, not changed here

Scribe's `transcript_edit` sometimes appends commentary such as "(This is a
single paragraph.)" to an English dictation (3 of 4 runs on one synthetic
clip, with the instruction before this change too), and `ValidationGate`
accepts it.
