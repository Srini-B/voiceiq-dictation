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
- Review follow-up: corrections carry the word positions they cover, so the
  same word fixed at another place is a separate edit. A correction the user
  undoes removes the fresh entry it taught, and fixing a word learned moments
  ago in another dictation still renames that entry. A fix is forgotten only
  when its original words are back, not when a longer edit covers it, and a
  revision made after the 120 s window is learned as a new word.
- Review follow-up: an edit beside a learned name extends it only when the
  added words are capitalized, not a case change, and a respelling; an undo
  keeps a word another tracked dictation in the field still teaches.
- Known limits: the respelling bound rejects some phonetic name fixes
  ("shivon" → "Siobhan"), the same bound the iPhone classifier uses; deleting
  a learned word leaves its entry. A neighbour that only changes case
  ("whisper flow" fixed to "Wispr", then "flow" to "Flow" after a pause) does
  not fold into the learned name, because a case change alone cannot be told
  from sentence case or a second name ("Wispr Slack"); fixing both words
  before the 4 s settle still learns "Wispr Flow". A phrase that spans two separately
  learned fixes ("Wispr" and "Supabase", then the word between them) is not
  merged; both words stay learned. Nor is a fix that grows a learned word on both
  sides at once.
- Gemini Neon review follow-up: adjacent edits never merge across a sentence
  or clause break; a re-fix of a word learned moments ago keeps it when
  another fix in the field still teaches it; "Supa base" → "Supabase" revises
  "Supa"; starred entries are never revised; harvests are ordered by when
  they read the field. One auto-learned spelling per heard wording stays
  deliberate.
- Second Neon pass: the one-word respelling path requires a real respelling
  of the learned word; only the newest harvest may drop a field or move its
  pending value; a break added or removed while fixing pairs word by word;
  a protected entry no longer blocks learning the new spelling beside it.
  `EditLearnerTests` covers `learn(_:stillTaught:)`.
- Third Neon pass: a phrase merged into one word revises when the learned
  part starts (or ends) the merged word ("Py torch" → "PyTorch"); a break
  added after a learned phrase keeps the phrase whole; joining across a
  removed break needs every word capitalized; a protected entry's
  `learnedFrom` no longer blocks the new spelling; the field is not dropped
  while a Return capture is still diffing.
- Fourth Neon pass: the letters a one-word merge adds must respell the words
  merged in ("Wispr and" → "Wisprs" teaches nothing); a field tracked again
  after being forgotten ignores harvests started on the old one.
- Known limits: runs are cut only at the breaks of the side with more of
  them; two Returns in quick succession can drop the first capture's edits
  until the next poll; a lowercase merge across a removed comma ("eye,
  phone" → "iPhone") or a word-count change beside an added break teaches
  nothing.

## Verification

- `swift test --package-path VoiceIQCore` on a Mac satellite (Xcode 27):
  263 tests, 0 failures. New `EditDiffTests` cover separate and adjacent
  edits across a paragraph, edits a few seconds apart folding into a phrase,
  a learned word changed again, and rewording, punctuation and deletions
  teaching nothing. With the respelling check disabled, the rewording test
  fails.
- Mac Debug build (unsigned) succeeds.
- Not verified live in a signed app: the dictionary writes in
  `EditLearner.learn` run only behind Accessibility reads.
