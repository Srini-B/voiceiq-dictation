# Also spoken languages (2026-11-13, PR #44)

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

## Follow-up: remarks added by transcript_edit (fixed)

The maintainer asked that the formatting edit only reformat what was said
and never add notes or remarks. Measured again on the same 8 s English clip,
regenerated with the same text: with the paragraph line in the instruction,
10 of 10 edits appended a remark ("(This is a single paragraph.)", "(This is
a separate paragraph.)", "It's Monday."), also with a new "never add a
note, comment, label or explanation" line. Without the paragraph line, 0 of
6 did, and a 30 s dictation stayed one paragraph either way.

- The paragraph line is gone and the no-notes line is in.
- `ElevenLabs.addsNothing` rejects an edit with a word the speaker did not
  say (as often as said), allowing digits, a two-letter spelling or meaning
  fix and short abbreviations. The transcript as heard is used instead.
  Other scripts stay under `keepsNonLatinWords`.
- `testAnEditThatAddsARemarkIsNotUsed` uses the real transcript and the
  four remarks; all four pass without the guard. Real clean edits,
  Japanese punctuation and Tamil mixed into English still pass.

## Follow-up: one request per recording, languages for every provider

The maintainer rejected paying for one transcription per spoken language
and asked for the main language and Also spoken to apply to every provider,
for dictation and meetings, with every recording treated as possibly
multilingual.

- The per-language requests and the logprob pick are gone. Each dictation
  and meeting window is one request again.
- The language pickers moved from the ElevenLabs settings to Settings ›
  Dictation › Languages on Mac and iPhone (`SpokenLanguage`, formerly
  `ScribeLanguage`).
- OpenAI dictation, batch and live, now sends `languages[]` and, with two or
  more languages, a one-sentence prompt naming them. Gemini and OpenAI
  meeting windows get nothing (no prompt field, and a language list would
  either disable Gemini's smart mode or shut out other speakers).
- Help text says plainly that a short or accented phrase can still come out
  as the main language.

What a transcriber can use from the writing rules, and what it cannot:

| Writing-rules part | Sent to transcription | Why |
| --- | --- | --- |
| Spoken languages, code-switching | Yes (OpenAI prompt and `languages[]`, Scribe codes) | The model listens for them |
| Dictionary terms | Yes (`keywords[]`, `keyterms`, `custom_vocabulary`, as before) | Dedicated field |
| "Each language in its own script, never translated or romanized" | No | Made one short Japanese clip part Devanagari on OpenAI (4 of 6 runs) |
| Self-corrections, lists, email layout, tone, numbers, dashes | No | Rewriting, the writing model's job |
| Mishearing repair, sound-alikes, screen and field context | No | Needs the whole transcript or the screen |
| Question and injection rules, custom writing rules | No | About how to treat the text, not how to hear it |

### Measured, one request each (English main, Tamil and Japanese also spoken)

| Clip | ElevenLabs Scribe v3 | OpenAI gpt-transcribe (`languages[]` + prompt) |
| --- | --- | --- |
| Real 2.6 s Japanese phrase, non-native speaker | "No, Miss, I'm not hasta." | "Now miss on Mata Ashta." |
| Same, `language_code=jpn` (Scribe) | "直美さん、また明日。" | not applicable |
| Real 17.9 s English dictation | English, correct | English, correct |
| Synthetic Japanese sentence | Japanese script | Japanese script |
| Synthetic Tamil sentence | Tamil script | Tamil script |
| English with a Tamil clause | each in its own script | each in its own script ("late" kept in Latin) |

OpenAI's live session (`gpt-live-transcribe`) accepted the `languages` and
`prompt` fields (`session.updated` echoed them) and returned Japanese and
Tamil in their own scripts; the short Japanese phrase came back romanized
there too. Gemini was not run (no key); its behavior here is from the docs.

Conclusion: no single request on any provider tested brings back that short
accented Japanese phrase while English is the main language. Whole sentences
in clear speech and mixed sentences work. For a stretch in another language,
switching the main language from the menu bar is the reliable path on
ElevenLabs.
