# Dictations land on the right line next to existing text

2026-10-25.

## Why

Two MacBook dictations into Amp built one numbered list. The first landed
items 1 and 2. The second was cleaned to items 3 and 4, numbered correctly
from the field text, but landed as "…ready for review. 3. Address…" on the
same line as item 2.

Two steps lost the break:

- `ValidationGate.stripArtifacts` trims the model's reply. The model had
  started it with a blank line (seen in replay), and the trim removed it.
- `SurroundingText.spaced`, the join every insert path uses (Mac
  Accessibility insert, Paste last transcript, iPhone keyboard), could only
  add a space.

## What changed

- New `FieldLayout` (VoiceIQBridge) picks the gap before and after the
  inserted text from the lines on both sides of the cursor: a space, a line
  break, or a blank line. List items, quotes, table rows and headings each go
  on their own line, spaced the way the field already spaces them. A paragraph
  after a finished list, or an email body after a greeting line, starts after
  a blank line. A lowercase continuation and a number ending an unfinished
  sentence ("Meet at 3.") stay on the line.
- Spaces typed after the last word do not stop a needed line break, and a
  bullet, quote, or table row after unfinished prose always starts its own
  line (from PR #19 review). Only a number or letter label continues an
  unfinished sentence.
- `SurroundingText.spaced` and `fitted` use it. `fitted` chooses the gap
  from the model's casing before it capitalizes anything itself.
- The prompt is unchanged. A sentence asking the model to continue lists and
  leave line breaks to the app made it worse: a closing sentence after a list
  became item "3." in 3 of 3 runs, and the real case dropped from 3 of 3 to
  1 of 3 (gpt-6-astra, `low`).

## Verification

- `.amp/in/fieldjoin/` (not committed): 37 field scenarios through
  `SurroundingText.fitted`, including the real case, tight and spaced lists,
  bullets, letters, quotes, tables, headings, greetings, inserts before
  existing text, CJK, inline numbers, trailing spaces, spaces already after the cursor, and bullets after
  unfinished prose. 37 pass.
- `.amp/in/fieldeval/`: the app's cleanup prompt with field text, 8 cases ×
  3 runs on gpt-6-astra. The current prompt continued lists correctly in 8 of
  9 runs and kept all 15 control runs right. Its outputs, trimmed as the app
  trims them and fitted to the field, all land on the right line.
- `scripts/test.sh`: 143 tests pass. `scripts/build.sh` and
  `scripts/build-ios.sh` build.
- Not driven through a live dictation in the installed app.
