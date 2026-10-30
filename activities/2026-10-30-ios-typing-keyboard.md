# 2026-10-30: Full typing keyboard on iPhone

## Why

The owner pointed at the Raycast keyboard and asked for the same for VoiceiQ:
a full keyboard with our own features, good prediction, slide to type, English
only, QWERTY and other layouts, and none of Raycast's features. Until now the
VoiceiQ keyboard had only a mic, space, delete and return, so users switched
keyboards to type.

## Open source considered

- **FlorisBoard** (Android, Apache 2.0). Its slide-to-type classifier
  (`StatisticalGlideTypingClassifier`) is small and well-tested; ported to
  Swift as `SwipeClassifier`.
- **SymSpell** (MIT). Its English word and word-pair frequency lists became
  the prediction data. Its edit-distance lookup was not needed: one edit with
  key-distance costs plus `UITextChecker` covers two-edit mistakes.
- **KeyboardKit** (Swift). Closed source with a paid Pro tier for prediction
  and autocorrect, so not used.
- Apple's `UITextChecker` and `requestSupplementaryLexicon` supply spelling
  guesses, contact names and Text Replacements.

## Decisions

- Typing lives in the keyboard extension and works without Full Access or a
  network. Voice still goes through the app.
- The word list is a memory-mapped binary, not parsed JSON: about 3.5 MB on
  disk and almost nothing against the extension's memory limit.
- Keys are UIKit views with raw touch handling, so one press can be a tap, an
  accent pick, a swipe or a cursor drag, and gaps between keys still type.
- A known word is never autocorrected to another word ("its", "were", "by"
  stay). Only its own contraction or capitalization replaces it.
- Slide-to-type prior weight 0.25: tuned on 400 simulated noisy gestures; 0.1
  and 0.4 were both worse.

## Verification

- Mac harness over the shipped engine and data: 30/33 misspellings corrected
  like the iOS keyboard (misses: "helo" and "hellp" to "help" instead of
  "hello"; "ok" offers "OK"). Slide to type 357/400 first, 389/400 top three at
  0.15 key-width noise.
- iPhone 17e Simulator (iOS 27.0), driven through Device Hub with synthesized
  mouse events: typed `i dont think teh meeting is tomorow` + two spaces and
  the field read "I don't think the meeting is tomorrow. "; slid "thanks for
  your help" and got "Thanks for your help". Checked light and dark keys, 123,
  emoji, the voice panel and Settings › Typing in screenshots.
- `swift test`: 143 tests pass. Simulator build of all targets succeeds.
- Not verified on a physical iPhone yet: haptics, key sound, landscape, and
  how slide to type feels with a real finger.
