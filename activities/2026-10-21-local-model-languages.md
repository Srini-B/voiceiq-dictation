# Languages under the on-device models

2026-10-21.

## Why

The owner asked which languages Fluid Speech Mini and Nemotron 3.5 support,
and wanted that list shown under each model in Settings so users can see it
before they choose.

## Findings

- Fluid Speech Mini is trained on English only (FluidVoice model card on
  Hugging Face).
- Nemotron 3.5 was measured on English, Spanish, French, Italian, Portuguese,
  German, Chinese and Japanese, and accepts more through a language prompt
  (FluidInference model card).
- The app uses both in English only. `NemotronSession` calls
  `setLanguage("en-US")` and `ParakeetSession` decodes as English. This lock
  dates from 2026-10-10, so that the English tools and number formatting
  apply.

## What changed

- `LocalSpeechModel.languages` returns `["English"]` for both models.
- `LocalModelRow` shows "Languages: English" under each speech model. The
  view is shared, so iOS shows it under Fluid Speech Mini too. The "On-device dictation is English only." sentence left the
  English tools note, because the rows now say it.
- `docs/LOCAL_TRANSCRIPTION.md` records the model-card findings.

Nemotron's other languages are not offered. Turning them on needs a language
picker, a way past the `en-US` lock, and a check that the English tools stay
off for other languages.

## Verification

- Signed and notarized Release build 0.6.5 (50) from `scripts/release.sh`,
  installed in `/Applications` on the Mac mini.
- Settings › Dictation › Transcription, read through the accessibility tree
  and a screenshot: "Languages: English" sits under Fluid Speech Mini and
  under Nemotron 3.5.
- iPad Air 11-inch (M4) simulator, Debug build: Settings › Dictation ›
  Transcription shows "Languages: English" under Fluid Speech Mini.
- `scripts/test.sh`: 143 tests, 0 failures.
