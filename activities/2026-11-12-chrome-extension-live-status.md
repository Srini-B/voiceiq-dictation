# 2026-11-12: Chrome extension status updates live

## Why

After loading the extension in Chrome, Settings → Advanced → **Chrome
extension for meetings** kept saying "Waiting for Chrome to load it". It
changed to "Last heard from it …" only after leaving the pane and coming back.

The extension sends a `hello` event when Chrome installs or starts it, and the
native host (`VoiceiQLocalSpeech`, a process Chrome starts) appends it to the
browser speaker log. The app gets no signal from that process.
`BrowserExtensionSection` read the log folder once, in its initializer and
`.onAppear`, so the row showed what was on disk when the pane opened.

## What changed

- The Status row is a `TimelineView` that reads `BrowserExtension.lastHeard`
  every second while it is on screen. The status changes within a second of
  the first event, and "Last heard from it a minute ago" keeps counting. Each
  read lists one folder with at most eight day files.
- Polling follows `PermissionsSection`, which already polls each second for
  grants made in another process. A file watcher was rejected: before the
  first event the folder may not exist, and appending to a file does not fire
  a directory event.
- `docs/MEETINGS.md` says how the row refreshes.

## Verification

Not built or tested on a Mac yet. App tests for this project run on a
signed, notarized build from `scripts/release.sh`.
