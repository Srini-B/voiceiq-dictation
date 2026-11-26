# 2026-11-26: Keyboard polish (K1/D6)

## Why

The integrator's review of the Hex keyboard (K1/D6) asked for eight fixes after
comparing VoiceiQ's keyboard with Apple's on the same simulators: unclear
cursor and Paste last icons and uneven button sizes, long suggestions cut in
the middle, a generic mic on Dictate, small Cancel/Stop while recording, "Hel"
autocorrected to "Gel" on the iPhone SE, bar buttons out of line with the keys
in SE landscape, uneven rows and arrows on the cursor page, and the "#+=" key
and space-bar label.

## What changed

- Cursor control uses a caret-between-arrows symbol and Paste last a
  text-insert symbol. Every button in the row, including recording's Cancel
  and Done, is 44 pt wide with 6 pt gaps and draws as a key.
- Dictate carries VoiceiQ's mark (`DictateMark` in the keyboard's asset
  catalogue, made from the app's `BrandMark`) on the blue pill.
- The row is laid out between the keys' outer edges, so its ends line up with
  the keys in SE landscape, where Apple insets the keyboard 72 pt a side.
- Long suggestions: the type shrinks to 10 pt to fit whole, measured at each
  half point because SF is tracked wider at small sizes. Paste last leaves the
  row (to the cursor page) while a word needs less than 13 pt, and comes back
  only between words. When a word does not fit a third even at 10 pt, two
  suggestions share the bar, as on Apple's keyboard.
- "Gel": spatial autocorrect read the tap on H, 11 pt left of the key's centre,
  as G. A 1 to 3 letter prefix is no longer replaced when the model's best
  completion of it is likelier (`0009-voiceiq-unfinished-words.patch`).
- Cursor page: three rows of one height, chevrons for steps and
  arrow-to-line for line ends, Paste last beside paste, a blank space bar.
- Paste last with nothing dictated shows "Nothing dictated yet".

## Decisions

- Kept Apple's 72 pt landscape inset on the iPhone SE; Hex matches Apple.
- Kept "#+=" small: Apple's keyboard draws it at the same size.

## Verification

- Side-by-side captures with Apple's keyboard on the same simulators (iPhone
  SE and 17 Pro, iOS 26.5, light and dark, portrait and landscape): letters,
  shift, caps lock, long word, 123, #+=, cursor page and recording.
- `scripts/sync-hex-keyboard.sh 012bdbbe` reproduces `iOS/Keyboard/Hex`
  byte for byte with patches 0001 to 0009.
- `KeyboardTests` pass on the iPhone 17 Pro simulator (iOS 26.5).
