# 2026-11-26: Hex's QWERTY keyboard in the VoiceiQ keyboard

## Why

cyron asked for Hex's full iOS typing keyboard in place of the 0.7.12
Dictate-and-cursor keyboard, while keeping VoiceiQ's shortcut row (cursor
control, Paste last, Dictate handing off to the app), its recording strip
and waveform, and no Hex logo or in-keyboard recording. Two later rules from
him: the keyboard must still look like VoiceiQ's, with no Hex branding, and
it ships English only.

This reverses the 0.7.12 decision (`2026-11-22-mini-keyboard.md`). Unlike the
earlier attempt (closed PRs #57 and #58), no GPL code comes in: Hex's slide
to type is its own MIT code, not FUTO's.

## What changed

- `iOS/Keyboard/Hex`: Hex's keyboard at `012bdbbe`, copied by
  `scripts/sync-hex-keyboard.sh` from `iOS/Keyboard/Hex/MANIFEST`, with two
  patches: `0001` hides the Hex key and logo and turns off the bar's
  hold-to-dictate; `0002` gives the action keys VoiceiQ's accent and the keys
  VoiceiQ's keycap shadow.
- `iOS/Keyboard/Sources/HexGlue`: stand-ins that keep Hex's dictation,
  recording panel, style menu and translation off, pin English QWERTY, and map
  Hex's custom vocabulary to VoiceiQ's Dictionary.
- `TypingBridge` hosts Hex's `FullKeyboardView` and routes its typing through
  `EditController`. `KeyboardView` stacks VoiceiQ's shortcut row (or the
  recording strip while a dictation runs) over Hex's keys, or the edit panel
  in their place.
- `project.yml` builds `iOS/Keyboard/Hex` and `iOS/Keyboard/Resources` into
  `VoiceIQKeyboard`.
- English only: one language, no switcher, no detection, only English data
  (`en.hextm`, `emoji-index-en.txt`). Hex's code for its other layouts
  (`KeyboardLanguage` cases, Czech, German, Greek and Korean helpers) is
  still compiled but unreachable; cutting it out would mean rewriting about
  15 Hex files by patch, and each Hex update would then need those patches
  redone.

## Evidence (Mac satellite, Xcode 27.3, iOS 27.2 Simulator, Debug, unsigned)

- `xcodebuild build -scheme VoiceIQiOS` for iPhone 17 Pro: exit 0.
  `KeyboardTests`: 4 tests, 0 failures.
- `scripts/sync-hex-keyboard.sh 012bdbbe…` on a clean tree leaves `git
  status` with no changes: the vendored files are exactly Hex plus the patches.
- In Messages on iPhone 17 Pro and iPhone SE (3rd generation), light and
  dark: letters with predictions after typing "hel", the 123 layer, cursor
  control, the emoji panel, and the recording strip with its glow (the app's
  snapshot, heartbeat and level bars written into the App Group by hand).
  No Hex key or logo anywhere. The globe key shows in the key row on the SE
  only.
- Memory (`vmmap --summary` on the keyboard process): 35 MB after typing,
  123, cursor control and recording; peak 44 MB with the emoji panel and a
  slide-to-type word. Simulator figures; not measured on a device.

## Not done

- No screen in the app for Hex's keyboard settings (haptics, number row,
  key colours, Learn how I type); Hex's defaults apply.
- Not tried on a device or a signed build.

## Rollback

Revert the PR. The 0.7.12 keyboard comes back unchanged.
