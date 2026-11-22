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

## Follow-up: 44 pt strip, waveform, mini spacing (0.7.12 review)

- cyron found the 27 pt portrait strip cramped. Portrait now uses a 44 pt
  strip, close to Apple's suggestion bar, with the buttons and suggestions
  centred and equal room above and below. `HexGlue/HexStripHeight` sets it
  through `KeyboardMetrics.phoneOverride`, which the strip-layout patch adds
  (one more hunk; it applies to Hex 2a023f9 and to Hex main a5adb4c).
  Landscape keeps Hex's 42 pt. The keyboard is 270 pt tall in portrait.
- iOS 26+ draws a band over the top of third-party keyboards. It lies above
  the keyboard view (17.7 pt on the iPhone 17 Pro in the iOS 27.0 Simulator,
  in portrait only), so nothing sits under it, but the icons read 28 pt below
  the visible edge and 19 pt above the keys. Check on the first TestFlight
  device.
- Simulator: the strip measured 10.7 pt above and below its icons (17 Pro),
  11 / 10.5 pt (SE), 9.7 pt in landscape; the mini pill 11 pt both ways.
  Keyboard memory 33 / 42 / 42 / 44 MB (idle / paragraph / six slides /
  recording), against 26 / 42 / 42 / 45 MB before. The Simulator's mic gives a
  steady tone, so the bars sit near full height there; that they follow speech
  needs a device.
- The recording strip's glow became a waveform (`LevelWaveform`): 3 pt bars
  whose height follows the mic level, between the timer and Done.
- The mini view's bar grew from 58 to 68 pt, 11 pt above and below the mic.
