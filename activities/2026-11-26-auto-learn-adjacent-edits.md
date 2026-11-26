# Auto-learn: separate edits, adjacent edits as one phrase

## Report

- The request: when several words are fixed at different places in a pasted
  dictation, learn each one. When two words next to each other are fixed,
  learn them as one phrase ("whisper flowcast" → "Wispr Flow"). Do not learn
  rewording, punctuation-only changes or deletions.

## Findings

- Only the Mac learns from edits (`EditLearner`, `EditDiff`). The iPhone's
  Auto-learned list is the Mac's, synced through iCloud; the Hex keyboard's
  `DictationEditClassifier` is vendored but has no caller. Both devices
  therefore show the same entries.
- One diff already learned separate edits individually and adjacent edits as
  one phrase. Two gaps:
  - Each harvest diffed the field against the text of the previous harvest.
    Fixing "whisper" → "Wispr", pausing past the 4 s settle, then fixing
    "flowcast" → "Flow" learned "Wispr" alone and skipped "Flow" as an
    ordinary word.
  - A reworded phrase of 1–3 words ("call him tomorrow" → "ping Priya Monday")
    was learned whenever one of its words was outside the spelling dictionary.

## Change

- `EditLearner` keeps each insertion's original text and diffs against it on
  every harvest, so adjacent fixes made in separate steps read as one phrase.
- `EditDiff.steps` compares a harvest's corrections with the previous one's:
  skip what was seen, learn what is new, revise the entry when the transcript
  wording overlaps an earlier correction. A revision renames the fresh
  (120 s) auto entry in place and updates its `learnedFrom`; other fresh
  entries for parts of the phrase are removed.
- `EditDiff.corrections` drops replacements that do not read as a respelling
  (letters-only edit distance above max(2, half the longer side)), the bound
  the Hex keyboard classifier uses.
- `DictionaryStore.update(id:term:learnedFrom:)` can set `learnedFrom`.

## Verification

- `swift test --package-path VoiceIQCore` on a Mac satellite (Xcode 27):
  253 tests, 0 failures. New `EditDiffTests` cover separate and adjacent
  edits across a paragraph, edits a few seconds apart folding into a phrase,
  a learned word changed again, and rewording, punctuation and deletions
  teaching nothing. With the respelling check disabled, the rewording test
  fails.
- Mac Debug build (unsigned) succeeds.
- Not verified live in a signed app: the dictionary writes in
  `EditLearner.learn` run only behind Accessibility reads.
