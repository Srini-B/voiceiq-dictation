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
- Recording panel (follow-up): the small "Tap to finish" capsule became a
  full panel with a live waveform, timer, cancel and stop. The level saturates
  for loud speech, so bars are drawn at level^1.4 with a small per-bar
  variation; without it a sentence read as a flat block. Checked in the
  Simulator with the debug simulated mic (now emitting the file's real
  loudness) and real Claude + Nemotron keys: recording in light and dark,
  "Writing…", and the inserted text. Selecting "waveform" in the field showed
  the "Add “waveform” to Dictionary" chip.
- Feedback from 0.6.14 (59) on device, fixed after:
  - Letters sat low on the keys: the label centred the font's line box.
    Measured lowercase about 4 pt low; now centred on x-height or cap height.
  - The slide trail drew behind the keys (layer added before the key views).
  - Slides from the edge of a key were typed as a tap: the slide needed
    0.75 key widths of travel, so "we" from the right of W was too short.
    A harness over the shipped word list showed the word matcher is not the
    cause: off-centre starts and ends up to half a key kept top-1 at
    370/400 or better, and widening the start/end keys made it worse.
  - Key sound never played: `playInputClick` works only from the root input
    view. Haptics created a new generator per tap, which can fire before
    the engine is ready.
  - Added the Raycast keyboard's themes. Checked each in the Simulator, light
    and dark, plus a slide of "we" from the right edge of W.
- Web feedback pass (Reddit, Apple Community, Wirecutter, MacObserver,
  AppleInsider, SlashGear, PCMag and App Store reviews of Gboard and
  SwiftKey). Already true here: no real word replaced by another (the iOS 26
  "come → coke" and "ducking" complaints), no correction after the next word,
  delete fires on touch down, swipe and voice built in. Added: number row,
  hold a top-row letter for its digit, Short/Default/Tall height, delete
  after an autocorrection restores the typed word, no period beside space in
  search fields, and a guard so quick sloppy taps are not slides ("Slide to
  Type activates erroneously"). Not possible for a keyboard extension:
  clipboard history (iOS lets a keyboard read another app's copy only
  through the paste button), secure and phone fields (iOS forces its own
  keyboard). Not done yet: emoji search, one-handed mode.
  Verified in the Simulator: "teh␣" became "The ", delete gave "Teh" and
  space kept it; holding W typed 2; an 18 pt drift in 86 ms typed "w"; the
  same drift over 290 ms slid "we".
- Not verified on a physical iPhone yet: haptics, key sound, landscape, and
  how slide to type feels with a real finger.
- Live preview in Settings › Typing (requested 2026-10-30, so a change shows
  before the keyboard is opened). Built from the keyboard's own key views
  rather than a SwiftUI copy, so it cannot drift from what the keyboard draws.
  Verified in the Simulator: Number Row on added the digit row and removed the
  corner hints; Mechanical with Dark keys turned the whole preview dark;
  Predictions off emptied the bar, as on the keyboard.
- Learned word pairs and Dictionary sync (requested 2026-10-30). Pairs are
  keyed by word key, plus "." for a sentence start, and need two uses so one
  stray sequence is not predicted. Learned words reach the Mac through the
  Dictionary's existing iCloud sync rather than a new channel: the keyboard
  publishes its most used words, the app imports each once. Capped at 200
  and 3 uses, because `DictionarySync` stops syncing the whole Dictionary
  past 900 KB (about 250 bytes an entry) and a typo kept twice should not
  become a Mac cleanup hint. `vocabulary()` now ranks manual entries above
  auto-learned ones so keyboard words cannot push the user's own out of the
  100-word prompt list.
  Verified: a scratch Mac harness over `TypingEngine`, `Lexicon` and
  `LearnedWords` with the shipped `lexicon.bin` ("call " gave the, for, to;
  after two "call Nitin" it gave Nitin, the, for; "call N" offered Nitin; a
  learned "so" led at a sentence start; one use predicted nothing; caps, save
  and reset held). In the Simulator the app imported a published list as
  Auto-learned and skipped a word already imported. Typed on the keyboard
  in the Simulator after the 0.6.16 crash fix: "good night" once left
  "good " with to, for, and; twice put night first.
