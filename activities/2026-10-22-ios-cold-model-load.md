# Slow first on-device dictation after a long break (iPhone)

2026-10-22.

## Report

On iPhone with Fluid Speech Mini, after about eight hours without
dictating, the first dictation stayed on "Writing…" in the keyboard, then the
keyboard went back to its dictate state with nothing typed. In the app,
History had no entry, and a new dictation was refused with "Still working on
the last one". The first dictation finished some time later; the next ones
were fast. The Settings footer said only the first dictation after a download
is slow.

## Findings

- Cause of the slow load: Core ML specializes a model for the device on first
  load and caches the result outside the app. The OS drops that cache after an
  OS update and when the model is not used for a long time (WhisperKit's
  `Configurations.swift` documents this; Apple gives no API to check the
  cache). FluidAudio issue #1022 reports cold Parakeet encoder loads of 51 to
  181 seconds on iPhone. This is inferred for this report: the device's
  session log could not be read (the iPhone was locked over `devicectl`).
- Keyboard state: the keyboard shows the app's snapshot only while the app's
  heartbeat is under 3 s old, and falls back to the dictate state otherwise.
  It has no timeout of its own. The app was still mid-dictation when it was
  opened ("Still working"), so it had been suspended, not ended. Why it was
  suspended is not confirmed: with the default 30 s mic window the audio
  session runs through processing; with "Never" it closes at processing and
  only about 30 s of background time remains.
- Memory: both platforms already load the model per dictation and release it
  right after transcription. The Mac's helper process lingers 60 s with no
  model; the iOS app releases in-process. Nothing is held between dictations.
- Other apps (via the librarian, from source): FluidVoice (macOS only) and
  WhisperAX keep the model loaded for the app's life. Dictus (an iOS keyboard
  app on FluidAudio) loads at launch, runs one silent inference to warm it,
  keeps it loaded, serializes Neural Engine compiles, and allows 120–300 s for
  a cold load. WhisperKit offers a `prewarm` that specializes each model and
  unloads it. The FluidVoice iOS TestFlight app has no public source.

## What changed

- Settings footer: "The first dictation after a download, a system update or
  a long break takes longer while the model is prepared for this device."
- Keyboard: when the heartbeat stops while the snapshot says `processing`,
  the keyboard keeps the spinner and shows "Open VoiceiQ to finish"; a tap
  opens the app (`BridgeURL.app`), which resumes or recovers the dictation.
- Session log: "processed in Ns (foreground|background)" for each dictation,
  and "app opened Ns into processing".

## Not changed (options for the owner)

- Warm the model before it is needed: a load-and-release when the app comes
  to the foreground, or a nightly background task while charging, so the
  first dictation of the day does not pay for specialization.
- Fall back to cloud transcription when the model is still loading a few
  seconds after the user stops, and let the load finish in the background.
- Keep the mic session open until the text is delivered under "Never".

## Verification

- `VoiceIQiOS` Debug simulator build succeeded; `scripts/test.sh` 143 tests,
  0 failures.
- iPhone 18 Pro Max simulator with the VoiceiQ keyboard in Reminders: with the
  app stopped and the App Group snapshot set to `processing` and an old
  heartbeat, the keyboard showed the spinner and "Open VoiceiQ to finish".
  The simulator does not deliver taps to the keyboard, so the tap that opens
  the app was not exercised.
- Not reproduced: the cold load itself (the simulator does not use the Neural
  Engine) and the suspension on a device.
