# 2026-11-26: Drop the on-device writer and the Gemini language picker

## Why

Writing is now Gemini or Off. The on-device writer (LFM3-Omni-2B through
llama.cpp) added a 1.1 GB download and a vendored xcframework, and its output
fell short of Gemini's. The language picker for Gemini dictation went too:
Gemini hears the language itself, and the picker only narrowed its guess.

This was first part of PR #81 together with a rule-based tidy-up for writing
Off (adapted from Hex). Neon's review found that tidy-up still deleting or
changing words the speaker meant ("sorry for the delay" removing "the
update", "Delete that," removing a sentence, "err" and "mm" dropped as
fillers, "to slash costs" written "to/costs"). The integrator split the PR:
the removal ships alone, and writing Off keeps today's behaviour (the
transcript as heard, with the Dictionary's replacements) until the tidy-up
loses no meant word and scores 90 or more on D4.

## What changed

- Removed `LocalWriter*`, `PromptOnDevice`, `MeetingNotesPrompt+OnDevice`,
  `Vendor/llama`, the write messages in the speech helper and
  `TimeoutPolicy.localWrite`. `CleanupSource` is `gemini` or `none`; a stored
  "onDevice" reads as Off, so a local-only choice never turns into Gemini.
  `FileLayout.removeStaleFiles` deletes `Models/lfm3-omni-2b` at launch.
- On-device meetings with writing Off keep their transcript and a short note
  that no summary was written, as before.
- Removed `SpokenLanguage`, `SettingsStore.spokenLanguages`, the Mac and
  iPhone language sections and the `languages:` argument of
  `PromptV1.dictationPrompt`. The on-device model's own Language picker stays.

## Decisions

- The old `spokenLanguages` defaults key is left in place; nothing reads it.
- Hindi/English, Tamil/English, Spanish and French dictation keep working:
  Gemini detects the language from the audio, and the prompt never forced one
  unless the user had picked it.

## Rollback

Revert the merge commit. A user who had On device writing reads as Off on
this build; a reverted build reads the stored "onDevice" again, but the model
folder is gone, so it falls back as it did when the model was missing.
