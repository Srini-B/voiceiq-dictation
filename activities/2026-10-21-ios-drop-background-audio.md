# 2026-10-21: iPhone and iPad drop Background audio

## Why

The owner reported that the Background audio mode does not work on his
device and asked to remove it, leaving Keep mic on as the only behaviour with
its "Keep mic on after dictating" duration picker. Background audio was a
prototype from the 2026-10-13 Typeless parity pass, built on an SDK header
reading that was never measured on a device.

A first pass removed the duration picker too and fixed the window at 30 s;
the owner corrected that the same day. The picker is back, "Never" included.

## Decisions

- `MobileSettings.KeepActiveMode` and `keepActiveMode` are gone.
  `MobileSettings.WarmWindow` and `warmWindow` stay (key `warmWindowSeconds`,
  default 30 s), and so does the "Never" branch that closes the audio session
  during processing.
- `KeepAliveAudio.start(preferBuiltInMic:)` always mixes with others and
  always taps `inputNode`. `VoiceSession.keeper` became
  `isActive: Bool`; `keeperDescription` and `keepActiveModeChanged()` are
  gone. Session log lines name the mic state instead of a keeper.
- Settings › Dictation keeps the "Keep mic on after dictating" picker and
  its footer in the first section. The "Skip app switching" picker is gone:
  with one mode left it had nothing to choose, and "Never" already turns the
  warm window off. Home's session card no longer has a "Ready in the
  background" state.
- A stale `keepActiveMode` default is left in place and ignored. A stored
  `warmWindowSeconds` keeps its value.
- Review follow-ups (PR #14): changing the picker while a session idles
  reschedules the countdown from now ("Never" ends it at once), and Home's
  session card shows "Writing…" instead of "Mic is on" while the text is
  processed, since "Never" closes the mic during that phase.

## Verification

- iOS Release simulator build (`VoiceIQiOS`, iPhone 18 Pro Max) succeeded.
- Settings › Dictation could not be rendered on the simulator for the second
  pass: Simulator.app is absent from this Mac mini, so `axe` taps do not
  reach the booted device.
- Not exercised: the warm window on a physical device after this change. The
  code paths are the former Keep mic on ones, unchanged.
