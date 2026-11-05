# Context model for predictions, chosen_planarian for slides (2026-11-05)

**Why.** The keyboard already ships FUTO's context language model for slide
to type, but the suggestion bar used only word pairs from `lexicon.bin`.
A scratch eval (`.amp/in/ctxlm-eval`) showed that blending the model into the
bar mid-sentence raises next-word top-3 from 20.8% to 27.7% on DailyDialog
and from 20.1% to 27.5% on BBC news, and the owner approved it. At the same
time FUTO replaced `hungry_jellyfish` with `chosen_planarian` (retrained for
hyphenated, accented and apostrophe words; FUTO Keyboard commit f2c0791) and
fixed its context split so "don't" stays one word (commit 5a58ba0). Our
split still sent "don", "t" and capitalized sentence starts that the model's
vocabulary does not have.

**What changed.**
- Model: `swipe/chosen_planarian` replaces `swipe/hungry_jellyfish` (Hugging
  Face `futo-org/futo-swipe` at 315d425, same vocabulary). The library's
  built-in `scoring.json` has no entry for it and falls back to the encoder's
  weights with alpha 0, which turns the model off without an error. The
  keyboard now bundles `swipe/scoring.json` from the same revision and sets
  `scoring_path`; it logs "no scoring for the context model" at load if
  alpha is 0. `scripts/build-futo-swipe.sh` downloads both.
- Context words: `TypingEngine.contextWords(before:)`, used by slides and
  predictions. The last ten words of the line, split at anything but letters,
  digits, `_` and apostrophes, with ’ read as '. A word that starts a
  sentence, or that the word list lacks as typed, is lowercased when the list
  has it lowercase.
- Predictions: `FUTOSwipe predictAfter:` returns the model's logit for every
  word (`predict_next` on the existing engine). `SwipeRecognizer.nextWords`
  runs it on the swipe queue; `TypingController` asks once per context,
  drops results for an old context and refreshes the bar. `TypingEngine`
  stays pure Swift and takes the scores as `NextWordScores` (context, a
  word-to-logit table, the top 30). Score = logit + 0.25 × the word-pair
  score; completions also take 0.4 off per letter still to type. Not used at
  a sentence start. Learned followers still lead, blocked and offensive words
  are never offered, and the autocorrection applied on space is unchanged
  (with a correction pending, the model picks only the third slot). Models
  now load when Slide to Type or Predictions is on.
- Shared engine instead of a second `ContextLMScorer`: on a Mac the engine
  takes 19.0 MB, a standalone scorer 12.6 MB more (+11.5 MB in the process),
  and `predict_next` over all words about 1.1 MB. The engine has no
  `score()`, so completions outside the model's 32,767 words get the lowest
  logit of the others.

**Verified.**
- Slides, first 4,931 swipes of FUTO's test split, through `SwipeRecognizer`
  and `FUTOSwipe.mm` with the shipped `words.trie`, context from each swipe's
  sentence, first choice / top four:

  | Context | hungry_jellyfish | chosen_planarian |
  |---|---|---|
  | None | 92.1 / 96.3 | 92.1 / 96.3 |
  | Old split | 93.3 / 96.6 | 93.4 / 96.6 |
  | `contextWords` | 93.7 / 96.6 | 93.7 / 96.6 |

  Median 2.22 ms per slide before, 2.21 ms after (M2). Without `scoring.json`
  `chosen_planarian` scored 91.9 / 96.3 and the load log fired. With it,
  alpha after a slide with context: decoder 0.70, encoder only 0.66. The
  earlier 91.7 / 95.3 came from a different, uncommitted harness.
- Predictions, eval test sets, shipped `TypingEngine.swift` and
  `Lexicon.swift` compiled with the harness, scores from `predictAfter:` the
  way the keyboard gets them, top-1 / top-3, before → after:

  | | DailyDialog | BBC |
  |---|---|---|
  | Next word | 11.7/20.8 → 16.7/28.1 | 11.5/20.1 → 16.2/26.4 |
  | Completion, 1 letter (top-3) | 43.3 → 50.3 | 37.6 → 45.2 |
  | Completion, 2 letters (top-3) | 50.7 → 58.6 | 40.8 → 51.1 |
  | Completion, 3 letters (top-3) | 70.0 → 78.8 | 55.4 → 69.1 |
  | Keystrokes saved (0-2 letters) | 16.1% → 21.9% | 13.0% → 20.4% |

  The eval's gated hybrid had next word 27.7 / 27.5 and savings 23.8% /
  24.3%. With `hungry_jellyfish` the shipped path gave 26.6 on the
  DailyDialog dev set against the eval's 26.7, so the BBC gap is the new
  model (+0.7 DailyDialog, −0.9 BBC), not the code. Completions trail the
  eval because the eval re-ranked every slot, and 75-78% of mid-sentence
  2-letter positions have a pending correction whose slots stay the list's.
- Misspellings (the 33 from 2026-10-30, reconstructed): 30/33 alone and
  27/33 mid-sentence, before and after; the autocorrection is identical in
  every case.
- Speed (M2): model scores 6.4 ms per context on the swipe queue (p99 7.0);
  `suggest` 0.27 → 0.61 ms mean (p99 2.6 ms) on the main thread.
- iPhone Air Simulator, iOS 27.0, Debug build: "Thank you so " offers much /
  far / many; "She walked into the " house / city / home; a sentence start
  The / I / I'm; "I dont " becomes "I don't " with have / know / think, and a
  slide then types "see"; with Slide to Type off predictions still work.
  Footprint after typing and slides: 42-48 MB with slides on (before: 43),
  43-51 MB with only Predictions on (before: 43, models not loaded), 42 MB
  with both off. No crash reports.
- Not verified on an iPhone.

**Rollback.** Revert the changes to `FUTOSwipe.{h,mm}`, `SwipeRecognizer`,
`TypingController`, `TypingEngine`, `build-futo-swipe.sh` and the docs;
restore `iOS/Keyboard/Resources/swipe/hungry_jellyfish` with `git checkout`
and delete `swipe/chosen_planarian` and `swipe/scoring.json`.
