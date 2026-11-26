# 2026-11-26: Remove the Chrome extension

## Why

The unpacked Chrome extension for browser-meeting speaker identification was
dropped by product decision. Maintaining an unpacked MV3 extension, native
messaging host manifests across ten Chromium browsers, and DOM selectors for
meeting sites added complexity the product does not need while meeting
speaker identification is being reworked separately.

## What changed

- Removed `App/Resources/ChromeExtension/` (`manifest.json`, `page.js`,
  `relay.js`, `service-worker.js`) and its resource entry in `project.yml`.
- Removed the native messaging host (`BrowserHostServer`, `BrowserSpeakerLog`,
  the browser launch branch in `LocalSpeechMain.swift`, and the `chrome-host`
  process handling in `DebugLog`).
- Removed browser-speaker ingestion and naming (`BrowserSpeakers`,
  `BrowserExtensionInstalls`, `MeetingRoster`, and the extension-only
  `talkStart` / `talkSeconds` fields on `ScreenNames.Match`) and their tests.
- Removed the Settings › Advanced section (`BrowserExtensionSection`),
  profile detection, stale-extension notices, and launch-time refresh in
  `AppDelegate`.
- Kept all non-extension meeting speaker naming intact: screen-name reading
  (`ScreenNameSampler` + `ScreenSpeakerNames`, including participant count,
  steady single-word names, and `probablyMerged`), track-based attribution
  (`MeetingTranscriber.byTrack`), Gemini diarization and note speaker
  suggestions, and on-device speaker separation (`MeetingTranscriber.splitFarSide`
  and `LocalMeetingTranscriber`). `MeetingTranscriber.split` now calls
  `LocalMeetingTranscriber.renumber` directly.
- Added idempotent macOS launch cleanup (`FileLayout.removeRetiredChromeExtensionFiles`,
  called from `FileLayout.removeStaleFiles`) that removes
  `~/Library/Application Support/VoiceiQ/ChromeExtension`,
  `~/Library/Application Support/VoiceiQ/ChromeExtension.new`,
  `~/Library/Application Support/VoiceiQ/browser-speakers/`, and
  `NativeMessagingHosts/io.blue.voiceiq.browser.json` from each Chromium
  browser's Application Support folder.
- Left `scripts/check-app-bundle.py` as it was on main: it never checked the
  extension, and guards naming deleted symbols would only pin dead names.
- Updated `docs/MEETINGS.md`, `docs/PRIVACY.md`, `docs/DEBUG_LOG.md`,
  `docs/RELEASING.md`, `README.md`, and `DebugLogSection.swift`.

## Manual step for existing extension users

VoiceiQ cannot uninstall an unpacked extension from Chrome itself. Anyone who
previously loaded it should open `chrome://extensions` (or the Extensions page
in Arc, Brave, Edge, Vivaldi, or Chromium) and click **Remove** on **VoiceiQ
Meetings**.
