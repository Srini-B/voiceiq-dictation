# 2026-11-18: Keyboard memory and the globe fallback

**Why.** cyron reported that after an app update, or at random, iOS shows
its own keyboard, and tapping the globe never reaches VoiceiQ; picking it
from the long-press menu does.

**Findings** (iPhone 18 Pro Simulator, iOS 27.0, Release, b4be39f,
lobsters-mac-mini):

- After an update: the host app keeps the old extension's plugin UUID. Each
  globe tap logs `no such plugin (uuid not found)` and the Apple keyboard
  stays. The long-press menu activates a fresh UUID and works; restarting
  the host also clears it. No keyboard code runs, so the keyboard cannot
  prevent it.
- Launch is not the cause. In 40 cold launches, with and without the
  force-loaded FUTO/ExecuTorch libraries, iOS gave up 0 times and timings
  matched within noise. Our own code takes about 30 ms in init, 5 ms in
  viewDidLoad and 160 ms to the first frame; the swipe engine loads in
  27 ms off the main thread. A 2 to 10 s stall in viewDidLoad was usually
  waited out.
- A crash in viewDidLoad reproduces the report exactly: every globe tap and
  menu pick relaunches the keyboard, which dies, and the Apple keyboard
  returns within 0.6 s. No VoiceiQ crash or jetsam reports exist on the Mac;
  device reports are the missing evidence.
- Memory without the test driver's accessibility bundles (8 to 14 MB in the
  Simulator): about 35 to 42 MB while typing with slides; the emoji panel
  adds about 7 MB while open, 4.7 MB of which (glyph cache, `EmojiData`
  tables, SwiftUI) stays until the process ends. Published limits for
  keyboard extensions are 60 to 77 MB depending on the device; the
  Simulator enforces none.

**What changed.** On a memory warning the keyboard frees the slide models.
A Simulator memory warning took the footprint from 48.1 to 35.7 MB (base
build: unchanged); typing kept working, and after reopening the keyboard
slides and predictions came back.

**Not verified.** Anything on a device: the actual kill point, whether
warnings arrive before jetsam, and real crash reports.

**Rollback.** Revert the commit.
