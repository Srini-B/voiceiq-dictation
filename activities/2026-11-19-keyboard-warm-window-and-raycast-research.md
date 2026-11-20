# 2026-11-19: How Raycast skips the app switch, and a keyboard-aware warm window

## Why

The owner saw Raycast's iPhone keyboard dictate without switching apps once
it had started, and asked whether Raycast uses a trick VoiceiQ lacks.

## Findings

- Raycast uses no trick. Its manual (manual.raycast.com, Keyboard and
  Dictation pages) says the first dictation opens Raycast to start recording.
  After that, "Raycast keeps a session alive in the background for 5
  minutes, so you can dictate again without switching to the app each
  time". A Live Activity with an End button shows while the session is up.
  "Disable session" offers Immediately, 5, 10, 15 or 30 minutes, or 1 hour.
  Since iOS 26.4 Raycast cannot find the host app, so users swipe back by hand.
- Wispr Flow, Willow and KeyboardKit describe the same design: one trip to
  the app, then a background mic session. Wispr Flow's default is 5 minutes,
  and its countdown runs only while the Flow keyboard is not on screen.
  Typeless keeps a hidden picture-in-picture window instead (see the 2026-10
  Typeless notes).
- Apple's documents still give keyboards no microphone. "Configuring open
  access for a custom keyboard" lists "No access to microphone and speaker",
  and Full Access does not add the microphone. Apple has added no keyboard
  dictation API in iOS 26 or 27.
- VoiceiQ already runs the same session ("Keep mic on after dictating"). It
  differs from Raycast in three ways: a 30 s default instead of 5 minutes,
  a countdown that runs while the user types on the VoiceiQ keyboard, and no
  Live Activity for keyboard sessions.

## What changed

- The keyboard refreshes `SharedStore.keyboardSeenAt` every second while it
  is on screen with Full Access.
- When the warm timer fires, `VoiceSession` restarts it from
  `keyboardSeenAt` if that is still inside the window. The session now ends
  once the keyboard has been gone for the whole window, not a fixed time
  after the last dictation. "Never" is unchanged.

## Verification

See the report in the Amp thread that made this change. Simulator builds
only; the session itself needs a real iPhone.

## Update, same day: Raycast 1.5.5 records in the keyboard

The manual quoted above was out of date. Raycast for iOS 1.5.5 (19 November
2026, changelog: "Dictate right from the keyboard, without switching to the
Raycast app") no longer opens the app to dictate. Raycast has not said how.
stephancill/ios-keyboard-dictation (MIT, published the same day) reproduces
it with public API: a hidden `WKWebView` in the keyboard calls
`getUserMedia`, and WebKit records in its own processes. Its README says this
is Raycast's technique; that is the repo author's claim, not Raycast's.

anomalyco/hex (PR #1999, same day) uses the same capture and reports it
working on an iPhone 17 Pro on iOS 27.2 with the app quit; its #2005 keeps
music playing with a mixable session.

## Update: the keyboard runs the app's pipeline

The owner asked for no regression against dictating through the app. A first
prototype transcribed in the keyboard with a small client of its own and
lost the writing rules, dictionary, Translate, Ask, History and real-time
transcription. It was replaced: the keyboard now links VoiceIQCore and runs
the same `DictationCoordinator` and `GeminiTranscriptionService` the app
runs, with `WebMicCapture` as its `AudioCapturing`. Settings reach it through
`AppSettingsMirror`, keys through the App Group keychain access group, and
finished sessions through `KeyboardInbox`, which the app imports into
History. See docs/IOS.md "Dictating in the keyboard".

Decisions:

- The keyboard never opens the History or usage SQLite databases. A
  suspended process holding a lock in the shared container is ended by iOS.
- Keys move to the App Group access group on iOS. Anything with the App
  Group entitlement can read them: the app, the keyboard (only with Full
  Access) and the Live Activity. That is the cost of running the pipeline in
  the keyboard.
- When the in-keyboard microphone does not start, the empty session is
  discarded and the tap goes through the app.

## Verification (Mac mini, iOS 27.0 Simulator, placeholder key)

- `scripts/build-ios.sh`, `scripts/test.sh` (191 tests) and `scripts/build.sh`
  exit 0.
- Dictate, Translate and Ask each started and finished in the keyboard with
  Safari in front; VoiceiQ never came forward. Transcription failed only
  because the key is a placeholder, and the keyboard showed the app's notice.
- Opening VoiceiQ imported the five sessions into History with their audio,
  target app and retry button.
- Keyboard footprint: 48 MB idle, 50–52 MB typing, 55–56 MB while dictating
  with VoiceIQCore linked (48–51 MB without it).
- Not verifiable on the Simulator: real speech through WebKit (its input is
  the host's audio device), music mixing, the shared keychain in a signed
  build and the device memory limit.
