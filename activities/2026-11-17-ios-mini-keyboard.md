# iOS keyboard: mini keyboard view

## What and why

Requested 2026-11-17, after Granola's keyboard: a short keyboard for
people who mostly dictate, with a key to switch to the full one.

- **Size key** beside the space bar on the letters, 123 and #+= pages and in
  the mini view. It switches views and remembers the choice in the
  keyboard's own `UserDefaults` (`typing.mini`), so it works without Full
  Access.
- **Mini view:** the mic bar, led by the voice screen's waveform button, over
  two rows: edit, @ . , ? ! ' and delete; then 123, globe (where the system
  draws none), emoji, the size key, space and return. 123 shows the digits 1
  to 0 in place of the punctuation; @?! brings it back.
- **Height:** the mic bar plus two rows at the full keyboard's row height.
  Panels (emoji, edit, voice, answer), emoji search and number pads use the
  full height, and the keyboard returns to mini when they close.
- **Edit key, not shift** (product decision, 2026-11-17): with no letters, shift
  did nothing. The edit panel (cursor, selection, copy, paste, undo) is what
  fixes dictated text, and the mini view has no bar to open it from. The 123
  row gives the slot to the digits: ten digits, an edit key and delete left
  each digit about 22 pt wide on an SE.
- In email and URL fields on SE and iPad the size key stays (product decision:
  "Shrinking spacebar is fine"). At full widths the space bar came out 18 pt
  with a cut-off label on an SE, so that row's function keys are one letter
  wide and return 1.6 letters, leaving the space bar about 88 pt.

## Rollback

Revert the commit. The stored `typing.mini` value is then ignored.
