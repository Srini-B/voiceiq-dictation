# 2026-11-26: Tidy unwritten dictations by rule (writing Off)

## Why

With writing Off, an on-device dictation went in as transcribed, with "um",
"uh" and spoken corrections left in. Rule-based cleanup adapted from Hex
(`012bdbbe`, MIT) closes most of that gap with no model, no network and no
wait. The on-device writer's removal shipped first, on its own (PR #90).

## What changed

- New writing-Off tidy-up (`Tidy`, `TidyText`, `SpokenMarks`,
  `SpokenAddresses`, adapted from Hex) and `SpokenRepairs` (self-corrections
  and unmarked questions, written for VoiceiQ). Setting `tidyStyle`:
  Sentences (default), Messages, Lists, As spoken; shown as "Tidy dictation"
  under Speech only while Dictation is On device and writing is Off.
- Cleanup cases for scoring both writing paths:
  `VoiceIQCore/Tests/VoiceIQCoreTests/Fixtures/cleanup-cases.json` (161
  cases), run by `CleanupCasesTests`.

## Decisions

- **When a rule is unsure, the words stay.** People who turn writing Off want
  their words as spoken, so a lost meant word costs more than a leftover
  filler (integrator, after Neon's review of #81 at `dad826b`). From that
  review:
  - No "delete that" or "sorry" cues; "actually" only narrows ("actually
    just to Sarah"); only "no wait" reaches into the sentence before.
  - A correction that points back with a pronoun ("Scratch that, send it to
    Sarah", "no wait, she'll call me") stays as said: the dropped words are
    what the pronoun means.
  - "I mean" that corrects nothing stays; "you know" set off by commas goes.
  - Not removed: "period" (it ends "a trial period" too), "err", Spanish
    "mm" (millimetres), "ah".
  - Spoken mark words stay after an article or a describing word ("an Oxford
    comma", "the hashtag", "a new line of shoes") and as verbs ("to slash
    costs"); English never folds accents ("Colón").
  - Spoken symbols run before layout, so "open quote … question mark close
    quote" converts the mark inside the quotation.
- Default style is Sentences: closest to what Gemini writes.
- VoiceiQ names, not Hex's. No Hex UI was copied.
- The tidy-up does not run on the Gemini-failure fallback or on meetings.

## Verification

- D4 on the writing-Off path (Claude Fable 5.2,
  T-01a2177d-d730-720b-bf02-f5ffc2f25386): 99.2 over 161 cases at
  `fc6b481`, no instruction obeyed, no invented words. Its two lost-word
  cases (correction-scratch, correction-new-clause) now stay as said.
- `swift test --package-path VoiceIQCore` on a macOS 27 Mac satellite, and
  `xcodebuild build` for VoiceIQ and VoiceIQiOS.

## Rollback

Revert the merge commit. A stored `tidyStyle` key is harmless; writing Off
goes back to inserting the transcript as heard.

## Upstream re-check (Hex `db515bda..012bdbbe`, FluidVoice `87fbef8b..ffa6639e`)

Built: Hex's "at the rate" email rule (`SpokenAddresses`). Already on main
from other work: Hex `341046f8` (macOS 27.3 keystroke permission, #75),
`9d6e0990` (second ⌘Esc for long dictations) and `8c9489b6` (pill on the
active Space). Ranked for later:

1. FluidVoice `91d3b719` (GPL, clean-room only): dictation stays available
   while a meeting summary is written.
2. FluidVoice `1bf1eac7` (GPL, clean-room only): meeting memory cap scaled to
   RAM.
3. Hex `be3ead04` (clipboard phrase) and `4bdd1eef` (pausing browser media by
   name): small, low priority.
