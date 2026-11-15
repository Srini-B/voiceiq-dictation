# iOS keyboard: iOS-style number pads and a number pad key

## What and why

The number keys looked narrow and unlike iOS (asked by the maintainer, 2026-11-15).

- **123 and #+= pages:** the punctuation in the third row shares the row, so
  it spans the width and lines up with the rows above, as on iOS.
- **Number and decimal pads** follow iOS's: digits without letters, a flat
  delete and decimal separator that show a face only while pressed, and an
  empty corner instead of a blank grey key. Where the system draws no globe
  (iPhone SE, iPad), the corner holds the globe, beside the separator on a
  decimal pad. `KeySpec.Width.share` lets two keys split one column.
- **Number pad key** on the 123 and #+= pages (`KeyPage.numpad`): a 4×4 pad in
  any text field, with minus, space, delete, return and ABC. A key rather than
  a setting, so it is found where people look for numbers and the symbols page
  stays one tap away; in the third row, because the bottom row on an SE in an
  email field has no room left for the space bar.
- **Alternates popup:** cells shrink so every option fits on screen (holding
  − showed four of five), and the highlight starts on the first option, which
  is what lifting types (it showed one option and typed another).

Not changed: phone fields always get iOS's own pad; on iPad, iOS's own 123
page and floating number pad are not reproduced.

## Evidence (Simulator, iOS 27.0, Debug, test Mac)

`scripts/build-ios.sh` exit 0. Before and after screenshots on iPhone SE (3rd
generation), iPhone 17, iPhone 17 Pro Max and iPad Air 11-inch (M4): number
pad, decimal pad, 123, #+= and the new pad. On SE the pad's globe opened the
keyboard switcher; held delete repeats. Number pad key: 1 2 . 5 space 3 typed
"12.5 3" with the pad still up; ABC returned to letters. Holding −: + * / = %
on screen, release typed +, a slide to % typed %. Holding o: 9 first,
release typed 9. Not tried on a device.

## Rollback

Revert the commit.

## Follow-up: review findings (2026-11-15)

- The 4×4 number pad had no globe where the system draws none, so
  switching keyboards needed ABC first. ABC now shares its corner with the
  globe there.
- Slid-word capitals (`TypingEngine.userSpelling`): a lowercase saved
  spelling such as "cant" → "can't" was dropped as if it were a lone
  capital. It is kept now (regression case in `KeyboardTypingTests`).
