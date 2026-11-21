# Hex's keyboard, cleanup tagger, Swift 6 and iOS 18

**2026-11-21.** The product owner chose to replace the iPhone keyboard's keys,
suggestions, autocorrect, predictions and slide to type with
[Hex](https://github.com/anomalyco/hex)'s (MIT), English only, and to drop
FUTO Swipe entirely. Hex updates several times a day, so its files are
vendored unmodified and a daily job can re-run `scripts/sync-hex-keyboard.sh`.
The same change adds Hex's on-device cleanup tagger to the iPhone app and
moves every target to Swift 6 and iOS 18, which Hex's code needs.

## Why

- One maintained keyboard engine instead of our own `TypingEngine` plus
  FUTO's GPL-3.0 swipe library, its ExecuTorch build and its model licence.
- Hex's cleanup tagger removes ums, repeats and spoken self-corrections on
  the device, where today a failed or rejected writing pass inserts a
  verbatim transcript with only `FillerStripper` on it.

## Decisions

- **No patches to Hex.** Everything Hex's files need from the rest of Hex is
  in `iOS/Keyboard/Sources/HexGlue` and `iOS/App/Sources/HexGlue`. Two extra
  self-contained Hex folders (`TypingLog`, `Dictation/`) come in through
  `MANIFEST`.
- **English QWERTY only**, through the glue (`HexLanguageSettings`), not a
  patch to `KeyboardLanguage.swift`. Only `en.hextm` and `emoji-index-en.txt`
  ship.
- **Dictation stays VoiceiQ's.** Hex's key calls the same action as the mic.
  Hex's in-keyboard dictation, recording panel and translation are not built.
- **VoiceiQ's panels stay** around Hex's keys: mic bar and recording strip,
  voice panel and mode picker, emoji panel and search, edit panel with undo
  and redo, mini keys, Dictionary offer, host-app return. The keyboard
  publishes the words Hex learns to the Dictionary, as before.
- **Cleanup tagger hook:** at the `FillerStripper` fallback in
  `GeminiTranscriptionService+Cleanup.settle`, through an injected
  `VerbatimCleaner`, so VoiceIQCore and the Mac do not link Core ML code. The
  model loads while the writing request runs (a cold load took about 0.4 s in
  the Simulator, more than the 150 ms budget).
- **Swift 6 and iOS 18 everywhere**, macOS stays 14.0. Hand-checked Sendable
  conformances are listed in the commit and the report.

## What was lost

Settings and features of the old keyboard that Hex's keys do not have:
themes and key tone, keyboard height, number row, the QWERTZ, AZERTY,
Dvorak and Colemak layouts, blocked words (Don't Suggest), the Predictions,
Emoji Suggestions and "." shortcut switches, the space-bar slide Off option
and the delete slide's Characters and Off options, the 4×4 number pad from
the 123 page, the Settings › Typing live preview, migration of words the old
keyboard had learned, and undo steps that know about autocorrections.

## Verification

- `scripts/build-ios.sh`, `scripts/build.sh` and `scripts/test.sh` (188
  tests) pass. Each commit builds for iOS on its own.
- `KeyboardTypingTests` (7) and `VoiceIQiOSTests` (the real cleanup model)
  pass in the iPhone 18 Pro Simulator, iOS 27.0.
- By hand in the Simulator: typing, autocorrect, the strip, slide to type,
  the Hex key starting dictation, emoji search, the edit panel, mini keys and
  the voice panel.
- A Release build in the Simulator crashed when the mic started: Swift 6
  made `KeepAliveAudio`'s input tap block main-actor isolated, and the audio
  thread tripped the isolation check. Fixed with an explicit `@Sendable`
  block; two permission callbacks moved to their async APIs for the same
  reason.
- Keyboard memory (Release, Simulator, `footprint`): Hex 31 / 38 / 38 / 41 MB
  idle / after a paragraph / after six slides / recording, against main's
  39 / 41 / 41 / 43 MB. The cleanup model adds about 2.8 MB to the app.

## Rollback

Revert the branch's commits. The App Group keys Hex writes
(`keyboard.learnedWords`, Hex's settings) are ignored by the old keyboard.
