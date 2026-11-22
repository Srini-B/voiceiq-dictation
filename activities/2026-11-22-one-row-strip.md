# 2026-11-22 — One row above the iPhone keyboard's keys

## What and why

The product owner asked for one row instead of VoiceiQ's bar over Hex's
suggestion strip, and for the Hex key (the hexagon) to go from the strip.
VoiceiQ's buttons now sit at the strip's ends: waveform and Mini Keyboard at
the leading end, Edit and the mic at the trailing end, the three suggestions
in thirds of the room between. The keyboard is 44 pt shorter.

## Decisions

- Hex's layout reserves room for its own key only, so one patch
  (`iOS/Keyboard/Hex/patches/0001-strip-layout-hook.patch`, made with
  `git diff -U1`) adds `FullKeyboardView.stripLayout`. It applies to the
  pinned Hex commit 2a023f9 and to Hex's main at 9b8617e.
- Buttons are 36 pt wide and as tall as the strip (27 pt in portrait), the
  hit size of Hex's own strip pills.
- Under 360 pt (iPad's floating keyboard) Mini Keyboard moves into the voice
  panel's bar; each suggestion keeps about 69 pt (82 pt on a 402 pt iPhone).
  Fewer buttons rather than narrower suggestions: the suggestions are what
  the strip is for, and Mini Keyboard is the least used.
- The strip's mic takes the Hex key's touch (`HexKeyGesture`): touch-down
  arms the capture, a tap dictates, a 0.35 s hold records until release, so
  the hold stop gate from #58 still works. The Hex key's style menu,
  translation badge, warm mark and Full Access hint go with it; VoiceiQ had
  them switched off already.

## Verification

- `build-ios.sh`, `test.sh`, `build.sh` and the VoiceIQiOS tests exit 0.
  `testTheStripHoldsVoiceiQsButtonsBesideTheSuggestions` checks 402 and
  320 pt: no Hex key, the buttons in order, none over a suggestion slot.
- Release Simulator (iPhone 17 Pro, iPhone SE, iPad Pro 11): idle, typing,
  slide, recording, mini, edit, voice and emoji render; tap and hold-to-talk
  on the strip's mic insert text.
- Keyboard memory: 26 / 42 / 42 / 45 MB against 34 / 43 / 43 / 46 MB before
  (idle / paragraph / six slides / recording).

## Rollback

Revert the commit; delete the patch with it, or the next sync fails to apply it.

## Follow-up: even spacing, the glow back, Mini and Edit by the space bar (0.7.12 review)

- A 44 pt strip with an 8 pt gap below measured 28 pt from the keyboard's
  visible edge to its icons and 19 pt from them to the keys in a Simulator
  run where iOS drew its ~17.7 pt band above the keyboard. cyron asked for
  even room. A strip built around that band (26.5 pt, the band's height as
  the gap) then measured 5 / 21.5 pt, because the next Simulator runs drew no
  band. Hex's notes (dev, iPhone 17 Pro, iOS 27.2) say the same: iOS draws
  the band in some presentations and not others, and a keyboard can't tell.
  So the strip now runs from the keyboard's top edge to the keys, 44 pt in
  portrait and 50 pt turned, with its content centred: even without the
  band, about 17 pt more room above the content with it. The mini view's mic
  bar follows the same rule.
- The red-bar waveform tried in its place was reverted: cyron wants 0.7.11's
  `LevelGlow` behind the recording strip, as before.
- Mini Keyboard and Edit moved from the strip to the bottom row, either side
  of the space bar, so the suggestions get about 106 pt each on a 402 pt
  iPhone. Hex's row leaves the room through a new patch hook
  (`KeyboardLayout.spaceSideRoom`) when the space bar keeps two letters'
  width; an email or URL field with the emoji key keeps Hex's row and the two
  buttons go back to the strip.
