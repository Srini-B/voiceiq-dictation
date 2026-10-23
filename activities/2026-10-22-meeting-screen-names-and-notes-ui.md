# Speaker names from the call screen, new Meetings layout, Markdown export

2026-10-22.

## Why

On-device meetings labelled people "Speaker 1", "Speaker 2". Call apps show
each speaker's name on their tile, and other note takers use that. The
Meetings window put every action in one row of buttons, and Export only
opened the meeting folder in Finder.

## Decisions

- **No screenshot reaches disk.** The user asked for screenshots to be
  deleted once a meeting is done. Instead, each snapshot is read in memory
  with Vision and dropped at once, so nothing accumulates and nothing needs
  cleanup. Only `(time, names)` samples are saved (`screen-names.json`,
  44 KB for 10 minutes), because Retry and Redo need them to match again.
- **Statistics, not a model, assign names.** A name must be on screen far
  more often while one speaker talks than overall. Window titles and labels
  that are always on screen get no speaker. The notes model only filters
  the remaining "seen" list down to people (`participants`) for the Assign
  speakers list; an NLTagger probe found no person names without context.
- **Presence badges are stripped** ("Robert Hunt Busy" → "Robert Hunt").
  Found in the first test run.
- **No calendar and no Accessibility readers yet.** The user ruled out the
  calendar. Granola-style reading of Zoom, Meet, and Teams through the
  Accessibility tree needs live calls to build and check; it is a follow-up.
- **ffmpeg is not needed by the app** (AVFoundation reads and writes all
  audio), so it is not bundled. It stays on the Mac mini as a test tool.
  yt-dlp was uninstalled after downloading the test recording.
- **Export goes to Downloads** as one Markdown file, notes above transcript
  for "Notes and transcript". The meeting folder no longer gets `notes.md`.
- The main window is now resizable; below 680 pt of detail width the notes and
  the transcript take turns instead of sitting side by side.

## Verification

Installed notarized build (0.6.5 + these changes), Fluid Speech Mini and
Nemotron 3 Diarization on device, GitLab "Product Analytics Sync" Zoom
recording (YouTube `U3nv6PGB17E`) played full screen with `ffplay` for 10 min:

- 151 snapshots, all with name-like text. 7 of 7 diarized speakers named, all
  correct when checked against direct address in the transcript ("Max,
  anything to call out?" answered by the speaker named Max Woolf, and so on).
- The meeting folder held only `meta.json`, the three `.caf` tracks,
  `local-words-v1.json`, `transcript.json`, `notes.json`, `screen-names.json`.
  No image files.
- App CPU while recording, sampled every 10 s: median 11 %, peaks of 130–177 %
  for one sample at a time (Vision reading five regions of a 1920×1080 frame).
- `scripts/test.sh`: 143 tests passed. macOS and iOS targets compile.

## Rollback

Turn off Settings → Dictation → Read names from the screen to stop sampling.
Code rollback: revert this change; old meetings decode without the new fields.
