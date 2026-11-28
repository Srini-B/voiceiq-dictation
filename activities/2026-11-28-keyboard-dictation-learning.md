# 2026-11-28: The iPhone keyboard learns from fixes to dictations

## Why

Hex's keyboard learns from the fixes you make to dictated text; VoiceiQ's
did not ("Learning from your edits: Not yet" in `docs/IOS.md`). cyron's
call: "Bring it but make it on and don't give option on ui to turn off and
keep improving it." So it is always on, with no switch, and also runs with
Learn how I type off. What it learns is removable in the Dictionary's
Auto-learned section.

## What changed

- Hex's `DictationEditTracker` is vendored beside the classifier it drives
  (`iOS/Keyboard/Hex/MANIFEST`; `scripts/sync-hex-keyboard.sh` at the pinned
  `f5819f4c` reproduces the tree with no other change).
- `DictationLearning` (keyboard, owned by `TypingBridge`) follows each
  dictation the keyboard types in, as Hex's `KeyboardViewController` does:
  `willInsert` with the text around the cursor before it went in, `observe`
  on every edit by the keys, the edit panel or the app, `didUndo` on Undo
  dictation, `finish` when the keyboard hides or reappears and when Send is
  tapped. Only in fields `TypingJournal.allows` (no secure, credential,
  email, URL or no-autocorrect field). From a dictation kept with words
  replaced (`DictationOutcome.edited`, `.substituted` pairs), each fixed word
  goes to the app with the dictated wording as `DictionaryAddition.learnedFrom`,
  spelled as the field has it: Hex's classifier lowers a sentence-start
  capital, so `DictationLearning.spelling` puts back a capital the user left
  ("Saran went home" teaches "Saran"; a lowercase word stays lowercase), since
  a lowercase term would make the writer and the spelling pass lowercase the name.
  Rewritten, deleted, undone and redictated dictations teach nothing.
- The app (`DictionaryBridge`) learns such an addition with
  `DictionaryStore.learn`, the Mac's rule for a new word, now shared:
  `LearnedCorrection.isKnown` (already in the Dictionary or learned from the
  same wording) and `LearnedCorrection.teachesNothing` (ordinary English
  unless a name replaced wording that was not ordinary). Both moved out of
  the macOS-only `EditLearner`, which calls them as before. `CommonWords`
  asks `UITextChecker` on iOS, in lowercase, as it asks `NSSpellChecker` on
  the Mac. The result is an auto-learned entry with `learnedFrom`, which
  syncs through iCloud and shows under Auto-learned on both devices.

## How learned words affect later dictations on iOS

Auto-learned entries are vocabulary only (no `misspelling`, so never a
`ReplacementEngine` rule):

- Writing model prompt: `AssemblyAITranscriptionService.dictationPrompt` →
  `DictionaryStore.sanitizedVocabulary` → `vocabulary()` (first 100 of
  `ranked()`, user-added words before auto-learned ones).
- Tidied on the device (writing off, no key, writer failure):
  `AssemblyAITranscriptionService.write` → `SoundAlikeSpelling.apply` with
  every Dictionary term (English).
- On-device speech: `LocalTranscriber.sessionOptions`, first 256 of `ranked()`.
- The keyboard's suggestions and autocorrect: `SharedStore.dictionaryWords`.

## Verification

- `DictationLearningTests` (KeyboardTests, VoiceIQiOS scheme): "Sharon" fixed
  to "Saran" in a kept dictation is handed over as heard "Sharon"; a rewritten
  dictation, a deleted one and one deleted and dictated again ("Saran" the
  second time) hand over nothing; "Sharon went home." fixed to "Saran went
  home." hands over "Saran" with its capital.
- `EditLearnerTests.testAFixFromTheIPhoneKeyboardIsLearnedByTheMacsRules`
  (VoiceIQCore, macOS): `DictionaryStore.learn` keeps "Saran" heard as
  "Sharon" as an auto entry, skips "Then" → "Than", and skips a second
  spelling learned from the same wording.
- On Linux (Swift 6.2.1, Swift 6 mode): the keyboard test's scenarios run
  against the vendored tracker and classifier with the same results, and a
  control shows the redictation case yields a "Sharon" → "Saran" pair that a
  filter taking every pair would learn. `DictionaryStore.learn` and the moved
  rules type-check and dedupe as expected. Apple compiles and the
  `UITextChecker` path are left to CI and a device.
