# Auto-learn: names fixed by ear, deleted words forgotten

## Report

- The main complaint about dictation is that Indian names in the dictionary
  come out as English names. Fixing a misheard name to its right spelling is
  the edit auto-learn most needs to learn. #99 listed sound-alike name fixes
  ("shivon" → "Siobhan") as rejected, and deleting a learned word as leaving
  its entry.

## Findings

Measured on a Mac satellite (Xcode 27, macOS English spell checker) at
main 35351ad, before this change:

- Already learned: "Sreeni" → "Srini", "Karthick" → "Karthik", "Vikinesh" →
  "Vignesh", "Aravind" → "Arvind", "Sentil" → "Senthil", "when cat" →
  "Venkat", "Jai Shree" → "Jayashree". The letters bound accepts them.
- Rejected by the letters bound: "shivon" → "Siobhan", "lucky me" →
  "Lakshmi", "Mootoo" → "Muthu".
- Produced but then dropped as ordinary: "Sharon" → "Saran". The spell
  checker knows "saran", "ram", "raja", "shiva" and "bob" in lowercase, but
  not "sharon", "karen", "kumar" or "priya".

## Change

- `EditDiff.soundsAlike`: consonant skeletons that ignore vowels,
  aspiration, voicing, s/sh/ch/j, v/w/b/f/ph, Tamil zh as l and doubled
  letters, within a quarter of their length. Used only when every
  replacement word is capitalized, in addition to the letters bound.
- `EditLearner.teachesNothing`: an ordinary capitalized replacement is
  still a name when the heard wording was not ordinary.
- A learned word whose words the user deleted outright is forgotten, as when
  the original words are put back (fresh entries only, as before).
- Everything runs on device; no model calls.

## Verification

- `swift test --package-path VoiceIQCore` on a Mac satellite: 318 tests, 0
  failures. New tests cover twelve Indian, Tamil and Irish name fixes, names
  and rewording that must not pass ("Mark" → "Mike", "Raj" → "Priya",
  "call him tomorrow" → "call Priya Monday"), "Sharon" → "Saran" learned
  while "Then" → "Than" is not, and deletion forgetting.
- With the sound-alike branch disabled, the name test fails on "shivon",
  "lucky me" and "Mootoo"; with the ordinary-name exception disabled, the
  Saran test fails.
- Unsigned Mac Debug build succeeds. Not tested live on a signed build.
