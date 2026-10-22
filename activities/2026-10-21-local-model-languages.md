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

## 2026-10-22: language menu

The owner asked for a menu under the selected model to pick the dictation
language.

- NVIDIA's model card lists 40 locales for Nemotron 3.5 in three tiers. The
  32 in the "transcription-ready" and "broad-coverage" tiers transcribe out of
  the box, and all of them are in the installed model's `prompt_dictionary`.
  The earlier list of eight came from FluidInference's card and was
  incomplete. The eight "adaptation-ready" locales need fine-tuning and are
  left out.
- `LocalSpeechLanguage` (code and name) replaces the string list. The selected
  model's row shows a Language menu; the other rows keep a caption.
- `SettingsStore.localSpeechLanguage` stores one locale code. Nemotron is
  prompted with it instead of the fixed `en-US`. For a non-English code the
  English tools and English number formatting are skipped, because they would
  trim and reformat the speech as English.
- iPhone and iPad offer Fluid Speech Mini only, so their menu holds English.

### Verification

- Signed and notarized 0.6.5 (50), installed in `/Applications`. Settings ›
  Dictation: Fluid Speech Mini selected shows Language › English and
  "32 languages" under Nemotron. Selecting Nemotron shows the menu with all
  32 entries. Picking German stored `de-DE`; switching to Fluid Speech Mini
  showed English, and back to Nemotron showed German. Settings were restored
  afterwards.
- The installed helper, driven over its pipe with synthetic speech (`say`,
  16 kHz Int16 CAF):
  - en-US on English: exact.
  - de-DE on German: "Bitte schick mir den Bericht bis morgen früh. Ich muß
    Ihnen vor dem Meeting noch einmal lesen" (one word off, "ihn" → "Ihnen").
  - en-US on the same German clip, the old behavior: "schick mir den Bericht
    bis morgen fr. Ich muß Ihnen vor dem Meeting". Words were lost at both
    ends.
  - es-ES on Spanish: the sentence came through with two errors on the
    synthetic voice ("Mañana" → "ya", "diez" → "jef").
- iPad Air simulator: the Language menu shows English under Fluid Speech Mini.
- `scripts/test.sh`: 143 tests, 0 failures. One earlier run failed
  `testAccidentalChordIgnoredWhileInFlight` on timing; it passed three times
  alone and in the next full run.
- Not tested: a live microphone dictation in another language, and real
  (not synthetic) non-English speech.
