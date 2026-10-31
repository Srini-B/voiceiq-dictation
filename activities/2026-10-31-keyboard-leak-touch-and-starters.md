# Keyboard switching away, dead taps, same three starters (2026-10-31)

**Why.** On 0.6.19 the owner reported that iOS switched to Apple's keyboard at
random, also when reopening it; that suggestions took one tap in the middle,
two on the left and about four on the right; that taps and slides were often
lost; and that after a period the bar always showed the same three words.

**Keyboard switching away: memory leak.** Reproduced in the iPhone 17e
Simulator (iOS 27.0, Release build): each dismiss and reopen added about
14 MB that was never freed, 39 MB to 125 MB over six reopens. iOS ends a
keyboard extension at roughly 60 to 70 MB and shows its own keyboard. `heap`
and `leaks --traceTree` found two retainers:
- `KeyboardView`, `KeysArea` and `GlobeKey` held the
  `KeyboardViewController` strongly while it owned them. They now reach it
  weakly (`model.controller`, `typing.controller`).
- With that fixed the controllers were freed, but iOS kept each controller's
  view, and the SwiftUI view in it, alive through the view's trait
  collection (`_UICornerProvider` to `_UIInputViewContent` to the
  `UIInputView`). `deinit` now detaches the SwiftUI view.
After both: six reopens stayed at 18 to 21 MB, and each `TypingController`
and `SwipeRecognizer` was freed (deinit logs, since removed).

**Dead taps: transparent pixels.** iOS drops a keyboard extension's touches
on fully transparent pixels (Apple Developer Forums 702798; LimeIME's
IOS_CANDI_TOUCH.md). The SwiftUI root was `.clear`, so a suggestion took a
tap only on its letters (or on the autocorrection pill, often the middle
one), and taps between keys, which `KeyboardKeysView` sends to the nearest
key, did nothing. Reproduced in the Simulator with mouse-driven taps through
Device Hub (90 ms, 2 pt of movement): taps beside or above a suggestion's
letters missed 6 of 6, and taps in four key gaps did not type. The root now
has a 1% gray background; the same 11 taps all worked. Screenshots differ by
one level out of 255 at the bar and the gaps.

**Same three starters.** At a sentence start the bar shows learned starters
used at least twice, then "I", "The", "I'm". Starters were kept to 12, like
the next words of any word, and a starter used once was dropped as soon as 12
others came in, so a word used every 15th sentence was often never learned
(a scratch run of `LearnedWords` over 60 sentences: "Thanks" learned in some
runs, not others). Sentence starts now keep 200; the same run learns it every
time. In the Simulator, "Maybe. Maybe. " put Maybe in the bar.

**Not reproduced.** Slides and key taps on keys always registered in the
Simulator. On the phone, the gaps (now fixed) and the memory pressure before
iOS ended the keyboard are the likely causes; neither was measured on a
device.

**Rollback.** Revert the commit.
