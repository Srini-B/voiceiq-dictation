# The keyboard's Add to Dictionary chip ends with the selection (2026-11-16)

**Why.** A tester reported that after selecting a word, the suggestion bar's
"Add “word” to Dictionary" chip stayed once they kept typing, and predictions
never came back. It had been like this since the chip shipped in 0.5.1.

**Cause.** `DictionaryOffer` kept the offer and recomputed it only in
`KeyboardViewController.textDidChange` and `selectionDidChange`. iOS does not
call those for the keyboard's own `insertText` and `deleteBackward`, so typing
or pressing Delete over a selection left the chip offering the old word. In
the iOS 27.0 Simulator, tapping elsewhere in the field, dragging on the space
bar and the Edit panel arrows did bring predictions back, because iOS reports
those.

**What changed.**
- `TypingController.refresh()`, which runs after every edit, now also reads
  the selected text into `selection`. `DictionaryOffer` no longer stores an
  offer; the bar asks it with `offer(selection:)`, so the chip and the
  predictions come from the same read.
- The voice panel's space, Delete and return keys now refresh typing too.
- `KeyboardTypingTests` now compiles the keyboard's Typing and Swipe code
  (with FUTO Swipe and VoiceIQBridge linked as in the extension), and
  `TypingControllerTests` checks that typing, Delete, space, return and a tap
  in the field each end the selection.

**Verification.** Simulator (iOS 27.0, Full Access): before the change,
typing a letter or Delete over a selected word left the chip; after it, the
bar shows predictions in both cases, the other three ways still work, and
tapping the chip still adds the word. `xcodebuild test -scheme VoiceIQiOS`:
2 tests, 0 failures.

**Rollback.** Revert the commit.
