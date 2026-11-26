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

## Later the same day: one row, settings, decisions

cyron asked for no extra height: the shortcuts moved into Hex's suggestion
row (cursor control and Paste last on the left, Dictate on the right,
suggestions between, truncated in the middle), and the recording strip takes
that row while dictating. `0003-voiceiq-strip-row.patch` reserves the ends
and middle-truncates; the keyboard is now exactly Hex's height. A rotation
left the old height behind (Hex learns its orientation after the
controller's trait change), so the controller rechecks it after layout.

He then gave full autonomy on two open calls:

- **Hex's code for other languages stays compiled.** It is unreachable:
  `languageOverride` pins English, only English data ships, and the
  language-switching paths return early. Cutting it means patching about 16
  Hex files (`KeyboardLanguage`, the autocorrect engine, accent picker, smart
  punctuation, shift, flicks, swipe) and redoing those patches on every Hex
  update, for no change a user can see. The binary cost is code only (the
  appex is 13 MB, 3.6 MB of it the English model).
- **A Typing card in Keyboard & Permissions**, in VoiceiQ's card style:
  Auto-correction, Auto-capitalization, Slide to type, Key haptics, Number
  row, Learn how I type, and Erase what it learned. These are the switches a
  user reaches for; Hex's key colours and Labs experiments stay at Hex's
  defaults so the keyboard keeps VoiceiQ's look. The card writes Hex's own
  App Group keys, so no Hex file changes.

Keeping dictation going while cyron dismisses the keyboard and switches
apps is a separate PR (app-side session work), not this one.

Evidence: `KeyboardTests` 6/6; re-sync of Hex at `012bdbbe` with the three
patches is byte-identical to the vendored tree; screenshots on iPhone 17 Pro
and SE, light and dark (letters, long word, 123, cursor control,
recording), SE landscape with the globe key and after rotating both ways,
and the number row switched on from the app. Memory 31 to 37 MB, peak 44 MB.

## Not done

- Not tried on a device or a signed build.

## Rollback

Revert the PR. The 0.7.12 keyboard comes back unchanged.

## Release fixes from the Gemini 4 Neon review (main 884208e)

Three keyboard findings blocked the 8:00 PM IST release; fixed on `keyboard-fullaccess-fixes`.

- **4, Full Access.** `KeyboardViewModel.hasFullAccess` was hard-coded true, so Hex's clipboard offer and the selection strip's Copy and Paste ran without Full Access. It now follows `controller.hasFullAccess`. Hex's own Full Access hint can't appear, because only the hidden Hex key raises it. The Allow Paste notice's Settings chip opened VoiceiQ's home; it now opens a new `voiceiq://keyboard/settings` route, which the app turns into its page in iOS Settings. The keyboard can't open that page itself: its `openURL` goes through the host app, whose page it would open.
- **5, strip behind VoiceiQ's row.** `setSuggestionsHidden` didn't store the flag, so a call before the keyboard existed was lost and Hex's `closeEmojiPanel` and selection end showed the strip again behind the recording strip or Dictionary offer. The flag is stored and reapplied whenever Hex refreshes its strip (patch 0006).
- **7, Add to vocabulary at 100 words.** `CustomVocabularySettings.sanitize` kept the first 100 terms, so the word just added was cut. It now keeps the newest 100, and a repeated term keeps its newest place.

Verified on a Mac satellite: arm64 Simulator build, KeyboardTests 6/6, a scratch run of `sanitize` (a new word over the cap is kept and is the only one requested), and in the SE Simulator the recording strip after opening and closing the emoji panel mid-recording, with no Hex words behind it.

## Follow-up: findings 6 and 8 (after #89)

- **8, secure fields.** iOS already swaps in its own keyboard for standard secure fields, but custom and web ones can reach a third-party keyboard. `TypingBridge.autocorrectionType` returns `.no` for `isSecureTextEntry`, and `TypingJournal.allows` (patch 0007) refuses `isSecureTextEntry` directly, so a password never enters the journal even if a field allows autocorrect. Password, new-password and one-time-code content types were already `.no` in both.
- **6, off screen.** `viewDidDisappear` now closes Hex's emoji panel, lets `handleMemoryWarning` drop the emoji library, and saves the typing journal, since iOS may end the extension before it is shown again.
