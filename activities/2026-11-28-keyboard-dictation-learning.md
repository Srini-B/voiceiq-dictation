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
  capital, so `DictationLearning.fix` puts back a capital the user left
  ("Saran went home" teaches "Saran"; a lowercase word stays lowercase), since
  a lowercase term would make the writer and the spelling pass lowercase the name.
  Whether the fix begins a sentence goes along (`DictionaryAddition.startsSentence`,
  into `LearnedCorrection.startsSentence`), so "Sory, I'm late" → "Sorry, I'm
  late" is not learned by the name exception (PR #168 review).
- Hex's pairs join word tokens with spaces, so the term is taken from the
  field and the heard wording from the dictation, from the first matched
  word's start to the last's end: "I tested GPT4 today." fixed to "GPT-4"
  teaches "GPT-4" heard as "GPT4", not "GPT 4" (PR #168 review).
- CodeRabbit on PR #168: a new dictation typed through `EditController`
  reached the dictation before as an edit, so one deleted and dictated again
  could teach; `KeyboardModel.onWillInsertDictation` now settles it on the
  field as it was first, for a delivery and for its draft. A field that
  stops being one Hex's journal may read (a username or password field in
  the same session) settles the dictation and is not read.
- The tracker remembers the input session (`documentIdentifier`) its dictation
  went into. Text from another session settles it where it was last seen, so
  moving focus to a field holding "…Saran…" no longer reads as a fix of a
  dictation typed into an empty field (PR #168 review). A dictation whose
  session UIKit didn't name (focus changing) is not followed at all.
- Edit window, as in Hex: `KeyboardModel`'s 0.1 s poll (`onPoll`) ticks the
  tracker, which ends the window at 60 s on the last observation, and every
  observation ticks first, so an edit after the window belongs to no
  dictation. One backspace after the window ("Sharon" → "Sharo", "tomorrow"
  → "tomorro") was learned before (Codex, Fable review). Accepted, as in Hex:
  a fix made inside the window stands if the dictation is deleted later.
- Read back only from the dictation's place: the term is found after Hex's
  anchor for the dictation in the span it last located, so earlier text with
  the same words ("I tested GPT 4 today.") is never used (Codex). A fix not
  found there, or found more than once with the same words around it (the
  dictation itself says "GPT 4" before the "GPT4" that was fixed), is
  skipped, and so is one with a comma, sentence or clause
  mark or line break between its words, which the Mac splits
  (`EditDiff.pieces`). The keyboard's sentence-start test follows the Mac's
  (list markers, a quotation opened after a comma). Known difference, on the
  safe side: Hex takes a dictation's capitalized first word for a sentence
  start, so a fixed first word that continues a sentence is marked as one,
  which can only stop its capital from counting as a name. The dictation's
  text is dropped once its result is in.
- Fable re-review and Codex at 66f67a5: a selection inside a dictation read
  as deleting it (the proxy's text before and after the cursor both leave it
  out; selecting the "n" of "Sharon" taught "Sharo"), so the selected text
  goes back after the text before. Hex's keyboard has the same gap. The edit
  window waits for a 3 s typing pause, up to 10 s past it, so "Sar…" at
  59.5 s finished as "Saran" at 61 s teaches "Saran", not "Sar". The last
  observation is dropped with the result.
- `CommonWords` on iOS fails closed: with no English `UITextChecker`
  dictionary every word counts as ordinary, so nothing is learned.
- Privacy: `docs/PRIVACY.md` describes the iPhone learning, and Settings ›
  Dictionary › Auto-learned has a footer saying where its words come from.

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
  home." hands over "Saran" with its capital, and "Sory, I'm late." fixed
  to "Sorry" is marked as a sentence start; "GPT4" fixed to "GPT-4" hands
  over "GPT4 → GPT-4", also with "GPT 4" earlier in the field; a dictation
  typed through the edit callback after a deleted one, an untouched one
  deleted by the keys after the window, one backspace after the window
  (after a poll tick, and as the first event after it), text in another
  field after a dictation into an empty field, and a dictation in an
  unnamed session hand over nothing.
- `EditLearnerTests.testAFixFromTheIPhoneKeyboardIsLearnedByTheMacsRules`
  (VoiceIQCore, macOS): `DictionaryStore.learn` keeps "Saran" heard as
  "Sharon" as an auto entry, skips "Then" → "Than" and "Sory" → "Sorry" at
  a sentence start, and skips a second
  spelling learned from the same wording.
- On Linux (Swift 6.2.1): `DictationLearningTests.swift` itself runs under
  swift-corelibs-xctest against the vendored tracker and classifier, 13 of 13
  passing (with a selection inside a dictation, and a word retyped across the
  window's end, both failing without their fix) (the dictation holding the fixed words twice hands over nothing;
  before, "GPT4 → GPT 4"); against the previous `DictationLearning` the window, span and
  unnamed-session tests fail as reported ("Sharon → Sharo", "tomorrow →
  tomorro", "GPT4 → GPT 4", "Sharon → Saran"). Clause breaks ("Wispr, Flow"
  dropped; "GPT-3.5", "1,000" kept), list-marker and quoted sentence starts
  and a fix missing from the field (skipped) were checked the same way. `DictionaryStore.learn` and the moved
  rules type-check and dedupe as expected. Apple compiles and the
  `UITextChecker` path are left to CI and a device.
