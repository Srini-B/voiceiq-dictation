# 2026-11-28: Tamil-English dictation from two Universal-2 passes

## Why

Release gate (b) for the AssemblyAI move: Tamil-English (D3, four cases) must
score at least 90. Gemini heard the audio and scored 95.9. On AssemblyAI the
Tamil option sent the recording to Universal-2 in Tamil and Luna wrote it.

## What we measured

Transcripts of the four TTS clips (`ml_ta`, `ml_ta_2`, `ml_ta_3`, `ml_ta_4`):

- STT-3.7 (Realtime and batch) does not know Tamil: Devanagari or English
  nonsense. A Tanglish `prompt` made it worse.
- Universal-2 `ta` gets the Tamil words right but respells English words in
  Tamil script and garbled `ml_ta_4`. `language_codes ["en","ta"]` gave the
  same text.
- Universal-2 `en` gives a usable Latin phonetic transcript of every clip.

The writer now gets both transcripts: RAW (Tamil) and LATIN (English), with a
note on which to trust for what (`PromptV1.latinSection`). Writers on that
prompt, 4 cases × 6 rounds through OpenRouter, judged by Claude Fable 5.2
(thread T-99661f2e):

| Writer | D3 Tamil-English | Writer p50 | Notes |
|---|---|---|---|
| GPT-6 Luna, effort none | 72.7 | ~1.1 s | keeps the retracted "Friday" in 4 of 6 rounds (scored 0) |
| Claude Haiku 5.5 | 83.0 | 4.4 s | misspells Tamil, invents a word |
| Gemini 3.5 Flash-Lite | not judged | 1.0 s | keeps "Friday" in 6 of 6 |
| Gemini 3.8 Flash, low (ships) | 94.5 | 2.1 s | ml_ta 97, ml_ta_2 95, ml_ta_3 92.7, ml_ta_4 93.2 |
| Gemini 3.8 Flash, minimal | 94.1 | 2.0 s | |
| Gemini 3.8 Flash, default thinking | 95.0 | 13.8 s | too slow |

An earlier Luna run scored 89.9, but its note quoted the test sentences as
examples. They were replaced with neutral examples before the table above.

## Decision

- `DictationLanguage` "Tamil-English (Universal-2, slower)" (`latinCompanion`)
  runs Universal-2 `ta` and `en` at once on the same FLAC; both are billed
  (two uploads).
- Its writer is Gemini 3.8 Flash on the gateway at low effort
  (`AssemblyAIConfig.mixedLanguageWritingModel`), unless a writing model is
  pinned. Other languages keep Luna.
- Cost per Tamil-English dictation of 20 s: two Universal-2 passes
  ≈ $0.0017, plus the writer ≈ $0.004–0.009 (≈ ₹0.5–1). The Gemini 3.8 Flash
  list price doubles on 2027-01-01 if the gateway follows Google.

## Verification

`eval/dictation/writer.py --latin-stt u2en-ta` runs the app's prompt
(`eval/promptdump`, now with `latin`) on the saved transcripts. Results
`ta6-*.json` in `eval/dictation/results` (gitignored).
