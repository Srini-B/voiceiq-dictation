# Keyboard casing from Hunspell's affix rules (2026-11-05)

**Why.** Typing "independence" mid-sentence became "Independence" on space.
The word list takes Hunspell's capitalized spelling of a word when Hunspell
has no lowercase form of it, and it only recognised lowercase forms that were
a listed stem plus -s, -ed, -ing, -er or -ly. Hunspell stores "independence"
as "dependence/IM" (the `in-` prefix), so the capitalized "Independence"
(the place name) won. Found while evaluating SCOWL 2026
(`2026-11-05-scowl-2026-eval.md`).

**What changed.**
- `scripts/generate-keyboard-data.py` also fetches Hunspell's `index.aff`
  (pinned at the same wooorm commit) and expands every lowercase stem with its
  prefix and suffix rules, including cross products, before deciding casing.
  The old ending check stays as a fallback for words Hunspell lacks ("as"),
  but only on listed stems: on built words it made "Kissinger", "Hastings",
  "Moses" and "Lester" lowercase.
- `lexicon.bin` regenerated. Only 17 display spellings change, all from
  capitalized to lowercase: independence, republican, reunion, reconstruction,
  honorable, reformation, proverbs, goth, zen, gen, est, dickens, degas,
  tangier, rainier, snider, breathalyzer. Word set, frequencies, flags and
  pairs are unchanged; the emoji files are byte-identical.

**Verified.** A Mac harness over the shipped `TypingEngine` and `Lexicon`
typed each of those 17 words mid-sentence: before, space capitalized all of
them; after, none. "monday" still becomes "Monday", "iphone" "iPhone", "i"
"I"; "jobs" and "as" stay lowercase; Kissinger, Hastings, Moses and London
keep their capitals; 23 common misspellings correct the same as before.
Regenerating twice gives identical bytes.

**Trade-off.** A lowercase display never forces a capital, so these words now
keep whatever the user types. Predictions show them lowercase too, so "the
Republican" is offered as "republican" after "the"; typing a capital keeps it.

**Rollback.** Revert the commit.
