# 2026-10-27: Hide the pill from screen sharing

## Request

While a meeting recorded, sharing the whole screen also showed the pill and its
recording clock, so the other people could see the recording. The owner asked
for an option that keeps the pill out of screen shares, as Granola and Wispr
Flow do.

## Decisions

- New setting **Hide pill from screen sharing** in Settings → Dictation, next
  to "Show resting indicator". Default on, because the products the owner
  named hide their overlays without asking.
- On sets the pill panel's `sharingType` to `.none`; off sets `.readOnly`, the
  previous behaviour. A change applies at once through `gtSettingDidChange`.
- It covers every pill state, not only meeting recording. The pill is one
  panel, and a dictation pill in a screen share leaks the same kind of thing.
- No private API. Apple has no public API that guarantees capture exclusion;
  `sharingType = .none` is what the named apps use.

## Verification

Probe on macOS 26.6.2 (a scratch Swift program, deleted): a magenta panel
with and without `sharingType = .none`, captured by a second process.

| Capture | Default sharing | `.none` |
| --- | --- | --- |
| `SCStream` live display capture | panel visible | left out |
| `SCScreenshotManager` display capture | panel visible | left out |

Signed, notarized 0.6.10 build from `scripts/release.sh`, installed in
`/Applications`. A second process captured the pill's screen area with
`SCStream`:

- Setting on: the window list reports sharing state 0 (none), and the
  resting pill is absent from the capture.
- Setting off (after relaunch): sharing state 1 (read-only), and the pill
  is in the capture.
- Flipping the toggle in Settings → Dictation while the app ran changed the
  sharing state from 1 to 0 without a relaunch.

Not tested: Zoom, Google Meet and Teams themselves, and a recording-clock
pill (the panel is the same for every state).
