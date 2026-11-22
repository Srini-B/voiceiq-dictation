# iOS keyboard: a voice keyboard without letter keys

## What and why

Decided 2026-11-22 by the product owner: VoiceiQ drops its full-size typing
keyboard and goes back to the early idea, a small keyboard for dictation. The
same day the product dropped Ask and Translate (the apps' side is a separate
change), so the keyboard keeps only Dictate and cursor control.
Keeping a typing keyboard on par with Apple's (layouts, predictions,
auto-correction, slide to type, emoji) cost most of the keyboard's code,
memory and review time, and people who dictate keep their usual keyboard for
typing anyway. The globe key switches between the two.

Kept:

- Dictate (the mic bar), through the VoiceiQ app as before. The keyboard
  still never records.
- The recording strip and its level glow, the processing states, notices and
  the Dictionary offer.
- The edit panel, in two rows: cursor steps, copy, cut, paste, undo, redo.
- The bottom row: globe (when iOS asks for one), the edit key, Paste last,
  space, delete and return. Delete and return keep the cursor panel usable
  on its own.

Removed:

- The mode picker (Ask, Translate) and the Ask answer panel.
- Letter layouts, the number and symbol pages and number pads, key views and
  themes, and the mini/full size key.
- Slide to type: the FUTO Swipe library, its models, dictionary, build
  scripts and licence notices. The keyboard no longer contains GPL-3.0 code.
- The word list, predictions, auto-correction, learned and blocked words,
  emoji (panel, search, suggestions and data) and their generation script.
- Settings › Typing, its keyboard preview, `KeyboardPreferences`, and the
  App Group keys `bridge.keyboardPreferences` and `bridge.keyboardLearnedWords`
  (values already stored there are left unread).

The keyboard moves to iOS 18 and the Swift 6 language mode, like the other
iOS targets.

## Salvaged from the closed full-keyboard branches

These fixes apply to the app and shared code without the full keyboard:
Swift 6 and iOS 18 (including the KeepAliveAudio input tap that crashed a
Release build when the mic started), the warm deadline cleared while a
meeting records, the Mac event tap lifecycle fixes, sparing the running
dictation in the launch recovery scan, and a cancelled request stopping
during its 429 wait.

## Verification

On the branch: `scripts/build-ios.sh`, `scripts/test.sh`, `scripts/build.sh`
and the `VoiceIQiOS` scheme tests (the new `KeyboardTests`) all pass. The
Simulator checks and memory readings are in the pull request.

## Rollback

Revert the merge of this branch. The typing keyboard comes back with its
settings; preferences and learned words stored before the removal are still
in the App Group and are read again.
