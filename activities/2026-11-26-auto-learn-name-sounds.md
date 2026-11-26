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

- `EditDiff.soundsAlike`: the same consonant skeleton (ignoring vowels,
  aspiration, voicing of k/g and t/d, s/sh/ch/j, v/w/b/f, Tamil zh as l and
  doubled letters) with at least three consonants. Used only for the first
  check of what was heard against a replacement written as a name
  (`nameLike`: every word capitalized, not only because it starts a
  sentence). Re-edits and merges compare letters only.
- `EditLearner.teachesNothing`: a name-like replacement that is an English
  word in lowercase is still a name when the heard wording was not
  ordinary. The one-time prune uses the same rule, so it cannot delete a
  synced "Saran".
- A learned word is forgotten when the only change over its words is a
  deletion inside them (the word itself, or one word of a phrase). Deleting
  the sentence around it forgets nothing (fresh entries only, as before).
- Everything runs on device; no model calls.

## Verification

- `swift test --package-path VoiceIQCore` on a Mac satellite: 321 tests, 0
  failures. New tests cover eleven Indian, Tamil and Irish name fixes;
  fourteen different names and words that must not sound alike ("Mark" →
  "Mike", "please" → "Balaji", "for" → "Priya"); sentence-start capitals;
  the sound rule staying out of merges and re-edits ("Srini Friday",
  "Karan" → "Green"); "Sharon" → "Saran" learned while "Then" → "Than" and
  "Sorry" are not; and deletion forgetting the word but not its sentence.
- With the sound-alike branch disabled, the name test fails on "shivon"
  and "tongue gum"; with the ordinary-name exception disabled, the Saran
  test fails.
- First Neon review (a71de92) found the sound rule leaking into merges and
  re-edits, sentence-start capitals counting as names, a skeleton loose
  enough for "please" → "Balaji", and sentence deletions forgetting names.
  All fixed here.
- Second Neon review (31ff01b): a narrowed revision lost its name flag;
  sentence starts after `:`, list markers and quotes, and a dictation that
  continues the field's sentence, were misread; `ph` no longer matched `f`;
  deleting the first word of a learned phrase kept it. All fixed; corrections
  now record whether they start a sentence and derive `nameLike` from it.

## Known limits

- Different names with the same consonants still pass ("Peter" → "Pedro",
  "Karen" → "Corinne"), also when re-editing a learned name ("Karan" →
  "Green" mid-sentence); only a name the user typed is learned. Re-edits
  must sound like both the heard words and the learned spelling, so a fix of
  a fix ("Shivon" → "Siobhan") is learned.
- Garbles with an extra or missing consonant ("lucky me" → "Lakshmi") or
  only two consonants ("Mootoo" → "Muthu") need the letters bound.
- A dictation that is only the name, or one deleted down to a few words,
  cannot be located, as before.
- Deleting a word from one of two copies of a learned phrase, or from a
  phrase followed by a comma, renames the entry instead of forgetting it.
- Title abbreviations read as sentence ends, so "Dr. shivon" → "Dr. Siobhan"
  is not learned by sound.
- Unsigned Mac Debug build succeeds. Not tested live on a signed build.
