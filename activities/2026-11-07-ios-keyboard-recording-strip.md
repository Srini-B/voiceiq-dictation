# 2026-11-07: Rambler-style recording strip, live words, one swipe engine

## Why

The owner reported four things about the iPhone keyboard:

1. Sometimes iOS shows its own generic keyboard after the mic bounce through
   the app. Recording continues.
2. When switching to VoiceIQ with the globe key, the waveform flashes briefly.
3. Real-time transcription shows no words on iPhone. FluidVoice shows them on
   its keyboard.
4. The recording waveform starts again, empty, whenever the keyboard reappears
   during a dictation.

## What changed

- **Recording strip.** The owner asked for the strip to follow Gboard's
  Rambler. While a dictation runs, the keys stay up and `RecordingStrip`
  replaces the suggestion bar:
  - cancel on the left, stop on the right, the timer in the middle;
  - behind them, a red gradient glow that rises from the bottom with the voice (`LevelGlow`);
  - while the text is written, only a spinner with "Writing…".

  The full-panel `RecordingPanel` and its bar waveform are gone. So is
  `SharedStore.level`, which only that panel and the old mic-bar waveform
  read.
- **Live words.** While recording, the app forwards the coordinator's
  `partialTranscript` to `SharedStore.liveText` (writer: app). The strip shows
  it on one line, newest words last, in place of the timer and the glow. With
  Real-time on, the words come from the provider's live socket (Gemini Live or
  OpenAI Realtime), which also gives the final text; the saved recording is
  sent only when the socket is refused or incomplete. (This branch first used
  local Fluid Speech previews; the 2026-11-10 cloud-only change removed them.)
- **Glow history.** `LevelBars` (VoiceIQBridge) holds the smoothed levels. The
  app appends one per level write and publishes them as
  `SharedStore.levelBars`, so a keyboard that reappears mid-dictation draws
  the history instead of starting empty.
- **One swipe engine per process.** `SwipeRecognizer.shared()` is held weakly
  and shared by every keyboard instance alive at the same time.

## Evidence (iPhone 17 Simulator, iOS 27.0, Debug, lobsters-mac-mini)

- **Mic bounce, footprint sampled every 0.2 s, 5 runs each.** Before the
  change, a new controller loaded its own FUTO engine 0.75 s before iOS freed
  the old one: two engines were live and the peak was 56.5 MB on average.
  After it, one engine was live and the peak was 43.8 MB. In one exploratory
  session on the old build, UIKit kept three controllers, each with an engine,
  and the extension reached 80–97 MB. That is above the roughly 60–70 MB limit
  at which iOS ends a keyboard. The Simulator does not enforce that limit, so
  the fallback itself was not reproduced, and nothing was measured on a device.
- **History after Home and back mid-dictation** (checked on the earlier
  bar-waveform version of this change): the history was full 0.8 s after the
  keyboard reappeared. Before the change it was flat on the left.
- **Live words** (checked on the earlier panel version): shown in light, dark
  and landscape, with `bridge.liveText` injected. The Simulator's simulated microphone sends no PCM to the live
  transcriber, so the preview path itself needs a device.
- **Recording strip** (final build): the keys stay up and keep typing while recording. In portrait and landscape, light and dark, the glow rises from the bottom to at most 75% of the strip and fades out at both ends. Live words replace the timer and glow, newest words visible. After stop, the strip shows only the spinner and "Writing…", then the suggestion bar returns. `swift test` passed 154 tests; `build-ios.sh` and `build.sh` exit 0.
- **Globe flash, still not fixed.** It reproduces on both builds as 4–5 frames
  of a stale "0:01 Listening" recording panel. Globe-back creates a new
  controller that has never drawn, so the image is not one of ours. It looks
  like a system snapshot of the keyboard taken after the bounce. A forced
  layout in `viewWillAppear` did not change it and was reverted.

## Rollback

Revert the commit. The new App Group keys are ignored by older builds.
