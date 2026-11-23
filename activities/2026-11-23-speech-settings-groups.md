# Speech settings grouped by job; Languages only for Gemini dictation

2026-11-23. Branch `speech-settings-groups`, not released.

## Why

cyron tried 0.7.13 (87). The Languages section (Spoken language, Also
spoken) only makes sense when Gemini transcribes dictation: the on-device
models take one language from their own picker, so the spoken languages
could only confuse them. And the Speech section listed every on-device model
in one column, so it did not say which model transcribes, which writes, and
what English tools are.

## Decisions

- Languages shows only while Dictation is Gemini, on Mac and iPhone/iPad. The
  stored languages are kept, so switching back to Gemini restores them.
- Only a Gemini dictation's prompt gets the spoken languages. With Dictation
  On device, the Gemini writing step for the on-device transcript and the
  Gemini audio fallback get no language hint. Meetings never had one
  (Gemini detects each language), so Meetings on Gemini is unchanged.
- The Speech section keeps the three choices. The models move into three
  groups with their own headers: On-device transcription (Fluid Speech Mini
  and Pro with its Language, Speaker Separation for meetings), Add-on for
  English dictation (English tools), and On-device writing (LFM3-Omni-2B).
- A group shows while its choice is On device. When it is not, the group still
  shows while a model of it is on disk or downloading, with a "Not used
  while…" note, so the model can be deleted. Hiding it outright would leave a
  1.1 GB download with no delete button.
