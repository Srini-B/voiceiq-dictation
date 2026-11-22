# Lessons from Hex: faster capture, typing fallback, media pause

**2026-11-21.** cyron asked what VoiceiQ can learn from Hex
(github.com/anomalyco/hex, MIT, mostly offline models). He then chose
which findings to build.

## Why

- A probe on the Mac mini (macOS 27.2, virtual Jump Desktop Audio input,
  2 × 10 runs) showed that an input tap delivers audio in 4,800-frame blocks
  every 100.3 ms whatever `bufferSize` asks for. So the first audio reached
  the app ~130–140 ms after the press, and `stop()` waited ~90 ms for the
  last block.
- An `AVAudioSinkNode` on the same prepared graph delivered 512 frames every
  10.7 ms: first audio after ~46 ms, tail wait after key-up ~4 ms.
- The mic itself opened 23–34 ms after `start()` with the prepared graph
  VoiceiQ already uses, against 170–233 ms cold. So Hex's "open the mic on
  touch-down" idea was already in place on the Mac.

## What changed

- **Capture (Mac and iPhone):**
  - `AudioCaptureEngine` records through a sink node. Its block only copies
    the buffer on the I/O thread.
  - Levels and the written peak keep 100 ms windows (`RMSWindow`), which the
    discard gate and the noise floor were tuned on. A last partial window
    counts only if it holds at least 50 ms.
  - `stop()` waits until the audio captured up to key-up (host time) is
    written, capped at 160 ms. Recording still ends at key-up.
- **Short dropouts:** gaps of 50–250 ms between buffers are filled with
  silence, as Hex does for a Bluetooth mic's startup hiccup (~140 ms).
  VoiceiQ still records from a Bluetooth default mic.
- **Start tone:** it waits 40 ms off the main thread. It is dropped or faded
  out on a cancel (accidental chord), and never plays after the stop, cancel
  or error sound. The stop tone already played at key-up; that is unchanged.
- **Pause Music and Spotify while dictating:** a new Mac setting, off by
  default (`MediaPause`, osascript). It plays again only what it paused.
  - Not on iPhone: pausing other apps needs a non-mixable session, and iOS
    then refuses the background start that the keyboard relies on
    (`KeepAliveAudio`).
- **Typing instead of ⌘V** (`TypingInserter`):
  - Windows App / Microsoft Remote Desktop is typed one key at a time, with
    the layout's key code. Numpad keys are never used. Curly quotes, dashes
    and ellipses become plain keys; text with any other character that has
    no key goes to the clipboard untyped, so a remote session never gets a
    wrong key.
  - Chromium 155–156 browsers are typed 20 UTF-16 units per event.
  - If the app in front changes part way, only the untyped rest goes to the
    clipboard.
- Sauce's minimum version is now 2.5.1, for `character(for:modifiers:)`.

## Not changed, by decision

- Not built (cyron's call):
  - iPhone warm-window reuse of the keep-alive input;
  - a Mac mic kept open with pre-roll;
  - avoiding Bluetooth mics.
- The keyboard gaps and holding a dismissed keyboard's result wait for
  cyron to confirm that in-keyboard dictation comes back.
- iPhone dead-job heartbeat: unchanged, because VoiceiQ already times the
  app out after 3 s (`SharedStore.heartbeatTimeout`), stricter than Hex's
  6 s.

## Verification (Mac mini, macOS 27.2)

- **Checks:** `scripts/test.sh` passed (195 tests, 0 failures);
  `scripts/build.sh` and `scripts/build-ios.sh` exited 0. The changed files
  added no warnings.
- **Timing harness:** the real `AudioCaptureEngine`, prewarmed as the app's
  `WarmEnginePool` does, 20 runs per pass. Base and branch passes
  alternated: 4 base and 5 branch passes.
- **Input:** the silent virtual "Jump Desktop Audio" device, 48 kHz. A
  built-in mic or AirPods were not measured.

| Medians | main (1d465a8) | this branch |
| --- | --- | --- |
| `start()` returns (mic open) | 28–43 ms | 39–42 ms (80 ms in one pass under load) |
| First audio reaches the app | 133–147 ms | 49–51 ms |
| `stop()` (Finish recording) | 82–94 ms | 36–43 ms |
| `tail drained` | +104 ms | +11 ms (sometimes +21 ms) |

- No `mic audio skipped` lines: the virtual device never drops audio.
- Recorded lengths now follow the stop time in ~10 ms steps. Before, they
  were always a whole number of 100 ms blocks.
- The Mac mini's running Chrome has framework 156.0.8078.80 loaded, with 157
  staged. `TypingInserter` therefore types there, which is right for the
  running process.
