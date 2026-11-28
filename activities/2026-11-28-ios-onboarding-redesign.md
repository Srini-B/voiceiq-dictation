# 2026-11-28: iPhone first-run flow redesign

## Why

The iPhone onboarding opened on a single welcome page and put the
microphone and the keyboard on one permissions page with a static
drawing of the two Settings switches. Switching to the keyboard with the
globe key was three lines of text inside the Try it card. New users
needed a picture of what VoiceiQ does and a visual guide through each
step iOS makes them do by hand.

## What changed

- The page's design follows the shared redesign tokens (white canvas,
  display titles, outline symbols, a checklist named for what the user
  gets).
- Three intro slides (dictation in any app, the keyboard, meeting notes),
  each with a small looping scene drawn in SwiftUI.
- Setup is one page per step: key, microphone, add the keyboard, switch
  with the globe key, try it.
- An animated walkthrough of VoiceiQ's page in Settings (Keyboards, the
  VoiceiQ switch, Allow Full Access and its alert) with a button that
  opens that page, and an animated demo of holding the globe key and
  picking VoiceiQ. Settings › Keyboard & Permissions reuses both.
- Each page checks itself off and moves on when its step is done:
  microphone granted, keyboard added, and the keyboard running with Full
  Access. Full Access and "keyboard in use" tick together, because iOS
  lets the app see Full Access only through the keyboard.

## References

Voicenotes' first-time setup on Refero (flow 14245) for the layered
globe-key illustration and the practice field, and Wispr Flow's keyboard
setup (flow 13657) for the privacy note beside the Full Access switch.
Ideas only; the visuals use VoiceiQ's own theme.

## Verification

- `VoiceIQiOS` Debug simulator build (unsigned, iPhone 18 Pro, iOS 27)
  succeeds at 25acc7dc with no errors or warnings; `swift test
  --package-path VoiceIQCore` passed at 76055a24 (349 tests, 0 failures).
  Later commits touch only iOS views and docs.
- On an erased iPhone 18 Pro simulator (iOS 27), a UI test drove the light
  flow end to end at 2fd5e232: slides, mic prompt, Settings › Apps › VoiceiQ ›
  Keyboards with both switches and Allow, back to the app, the globe menu,
  both checks ticking, and the automatic move to Try it.
- Runs found and fixed: a timed Full Access hint that showed after any
  focus change, the switch page's checks hidden by the keyboard, and the
  globe drawing flashing back after the ticks.
- In the cold simulator, Open VoiceiQ Settings opened the Settings home
  page rather than VoiceiQ's page. Not checked on a device.
- Not run: dark mode end to end, iPad, iPhone SE size, VoiceOver, and
  large text.
- Review: Claude Fable 5.2 (Neon's weekly limit was used up).
