# 2026-11-28: Remove more spoken disfluencies, within Hex's cleanup guard

## Why

The writing-Off tidy-up (`Tidy.spoken`) dropped "um" and "uh" and resolved
like-for-like self-corrections, but left stutters ("I I think", "the, the
office"), false starts ("Did you, have you seen it?") and comma-set "like" and
"you know". It is also the fallback the AssemblyAI path uses when the writing
gateway is down, on punctuated and capitalized input, so it must never lose
meaning.

Hex (github.com/anomalyco/hex, MIT) removes these with a 26 MB tagger model
whose proposals a cleanup guard filters (`ios/HEXShared/Formatting/CleanupGuard.swift`,
ported word for word to `src/dictation/cleanup/guard.rs` at `a0f0a858`; the
meaning-preserving rules in `guard/context.rs` at `e27726790`). VoiceiQ gets
no model, so the guard's categories became deterministic rules that propose
the words themselves.

## What changed

- New `VoiceIQCore/Sources/FormattingPipeline/SpokenDisfluencies.swift`, run
  in `Tidy.spoken`'s English path after `SpokenRepairs.correcting` and before
  `SpokenRepairs.askingQuestions`. It removes:
  - a repeat of one to three of the guard's function words, ending in one that
    cannot end a clause ("I I think", "the, the office", "in the, in the
    morning"), and a cut-off start ("w- we");
  - a false start of an auxiliary and a pronoun at a clause's start,
    restarted with an auxiliary and the same pronoun ("Did you, have you seen
    it?" → "Have you seen it?");
  - "like" and "you know" between commas mid-sentence, or opening a sentence
    with their comma ("Like, I don't know"); the comma before goes with them
    when the clause has two words or more and the next word is lowercase
    ("I went, like, to the store." → "I went to the store.").
- Tests in `TidyTests.swift`, each category with its near misses. No
  `cleanup-cases.json` expectation changes: none of its cases hold a repeat,
  false start or comma-set "like", and "Wait, you know, right?" stays.
- `docs/ON_DEVICE.md` (Tidy dictation) and the Hex entry in
  `THIRD_PARTY_NOTICES.md`.

## Decisions

- **Only what the guard admits at the tagger's base threshold.** Comma-less
  "like" and "you know" need the guard's `sureFloor`, which rules cannot
  give, so they stay ("it was like a dream"). Self-corrections stay with
  `SpokenRepairs`, unchanged.
- **"I mean" is never removed.** The AssemblyAI thread showed it emphasizes
  as often as it fillers ("It's good. I mean, really good."), and it is
  `SpokenRepairs`' cue, left in place on purpose in "We met on Friday, I
  mean, Monday works too". The step runs after `SpokenRepairs`, so a
  like-for-like correction ("Monday, I mean, Tuesday") is still resolved.
- **The tagger's judgement became word lists.** Hex lets the tagger decide
  that "had had" is grammatical. Here a repeat goes only when its last word
  is one that cannot end a clause (articles, subject pronouns, conjunctions,
  contractions), so "I had had enough", "I know that that works",
  "Whatever you do, do it" and "I love it, it works" stay. Content words
  never go ("a bag of tea, a bag of tea" stays, which Hex removes). "I want,
  I want to go" stays too: "What I want, I want to keep" has the same shape.
- **False starts are narrower than Hex's.** Any function-word fragment
  before a pause would drop "If you can," from "If you can, call me", so
  only a question restarted with the same pronoun counts.
- **Capitals.** A word capitalized mid-sentence is never removed, and a
  repeat said again with its capital stays ("Will, Will, are you there?"),
  covering keyterm names at a sentence's start. A removal that opened the
  sentence hands its capital to the next word.
- **`e27726790`'s structural rules hold by construction.** Comma-less "like"
  ("like we did yesterday") is never proposed; only exact repeats are, so
  parallel items ("a box of red pencils, a box of blue pencils") stay; the
  anaphoric and polarity rules guard corrections, which this step never
  proposes. Hex's desktop negation, emphasis and mentioned-filler rules hold
  the same way: no negation or content word is in the lists, and quoted
  words are skipped.
- **Dictionary terms are not passed.** `Tidy.spoken` keeps its signature and
  the Dictionary is applied after it; the rules only remove closed-list
  function words and "like" / "you know", and never a capitalized word, so a
  Dictionary term is touched only if it is one of those words.

## Verification

Pending Mac build: `swift test --package-path VoiceIQCore` (TidyTests,
CleanupCasesTests). Expected outputs were derived by hand from the rules; no
Swift toolchain in the orb.
