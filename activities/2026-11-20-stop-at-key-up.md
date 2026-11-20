# Recording stops at key-up

**2026-11-20.** The user asked for the recording to end the moment the
dictation is stopped, with no wait at all.

## Why

On 0.7.10, History showed one Mac dictation with Finish recording 1.64 s.
Its debug log had `carried capture 1518ms past key-up — you were still
talking`: the trailing capture kept the mic open after key-up while the level
read as speech, up to 1.5 s on the Mac (0.6 s on iPhone). Over one day on the
user's MacBook, 15 of 53 dictations carried past key-up and 10 ran to the cap.
Without it, Finish recording was 55–175 ms.

## What changed

- `DictationCoordinator.finalizeSession` stops the engine at key-up on Mac and
  iPhone, whatever the level. `captureTrailingSpeech`, the trailing thresholds
  and `latestLevel` are removed, with their tests.
- Short clips: the trailing capture used to add at least 0.25 s to a word
  released at once, which kept a short loud word ("Hi") above the 0.4 s
  local discard. Review caught that it would now be deleted unheard. Clips
  under 0.2 s are still discarded; 0.2–0.4 s clips are sent when their peak
  reached 0.3, which room tone does not.
- `AudioCaptureEngine.stop()` is unchanged. It still waits for the one tap
  buffer the input already holds (audio spoken before key-up), then stops the
  engine and closes the file. Tap buffers arrive about every 100 ms on macOS
  and iOS whatever `bufferSize` asks for, so this wait is 0 to about 105 ms,
  about 50 ms on average. Dropping it would cut the end of the last word.
  Making it shorter needs a lower-latency capture path (an `AVAudioSinkNode`
  at the I/O buffer size), which is a separate change.

## Verification

See the pull request: VoiceIQCore tests, Mac and iOS builds on the Mac mini.
