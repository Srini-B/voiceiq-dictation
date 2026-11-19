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
