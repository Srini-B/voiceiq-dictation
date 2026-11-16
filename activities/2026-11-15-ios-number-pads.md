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

## Follow-up: long-press popups on the top row (2026-11-15)

The maintainer saw the alternates popup on the top row run above the
keyboard and get cut off: no border at the top, and the highlight touching
the cut edge. The option glyphs also sat unevenly.

- The alternates popup and the key preview now stay below the top of the
  keyboard, over the suggestion bar or the top row's keys.
- The popup has 5 pt of padding on every side, and the highlight is one
  rounded box inside it rather than each label's background.
- Every option shares one baseline (`KeyCapView.labelOffset` over all of
  them), and long options shrink to fit their cell.
- A popup on a row's last key (p, the number pad's −) is kept on screen:
  with the padding it had run about 2 pt past the right edge.

Evidence (Simulator, iOS 27.0, Debug): `scripts/build-ios.sh` exit 0. On
iPhone SE and iPhone 17, holding e, o, p, a and the number pad's − shows the
whole popup inside the keyboard; measured on the screenshots, the − and p
popups have 2 pt on both sides. A slide onto % moves the highlight to the
last cell. A q press shows its preview inside the keyboard. e on iPad Air
11-inch (M4) too. Not tried on a device.
