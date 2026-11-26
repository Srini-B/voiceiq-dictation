# iPhone: "Starting…" until audio flows, and a cellular prompt for model downloads

**2026-11-26.** Two iPhone items from the Hex port. Hex is MIT; adapted logic
is credited in `THIRD_PARTY_NOTICES.md`. Hex reviewed at `a2d940e3` and
`9e41970e`.

## What

- **Recording only once audio flows** (Hex `a2d940e3`). The iPhone app
  published `recording` as soon as a dictation began warming, so the keyboard,
  the Live Activity and the Control Center toggle said VoiceiQ was listening
  while the microphone was still starting. On a Bluetooth route that can take
  seconds. `AudioCapturing` gains `onFirstAudio`, which `AudioCaptureEngine`
  fires on its first non-empty buffer, and `DictationCoordinator` publishes it
  as `audioFlowing`. Until then the app publishes a new snapshot phase,
  `starting`, which the keyboard shows with its existing "Starting…" label and
  spinner, and the Live Activity as "Starting…". The recording timer counts
  from the first audio. A stop before any audio cancels the start quietly
  instead of failing as "Microphone unavailable". The Mac does not read
  `audioFlowing` and is unchanged.
- **Model downloads on cellular data** (Hex `9e41970e`, changed per cyron:
  "If a user is trying to download a model on cellular data, show a
  confirmation popup once and let them download it."). On an iPhone on cellular
  (or an expensive path, such as a hotspot), Download or Retry on any on-device
  model first shows "Download on cellular data?" with the manifest's size.
  Download starts it over any network; Cancel starts nothing. The consent
  belongs to that download: network drops, retries and a move from Wi-Fi to
  cellular never ask again, and a download started on Wi-Fi counts as
  consented. When it finishes or is cancelled, the next download asks again.
  No Wi-Fi-only mode and no setting; the Mac never asks. The rule is the pure
  `CellularDownloadConsent`; `CellularModelDownloads` watches `NWPathMonitor`
  and Settings › Dictation shows the alert.

## Why

Hex shows "starting" until the first buffer for the same reason: telling the
user to speak before the mic records loses their first words. Hex holds model
downloads for Wi-Fi with a "Use mobile data" button; cyron chose a one-time
confirmation instead, so a download is never silently held.

## Verification

Pending Mac build: `swift test --package-path VoiceIQCore` (new
`CellularDownloadConsentTests`, `DictationCoordinatorTests.testAudioFlowsOnlyAfterTheFirstBuffer`),
and the VoiceIQ and VoiceIQiOS scheme builds. Not run on an iPhone: the
Bluetooth start, the alert on cellular, and a Wi-Fi to cellular switch mid
download need a device.

## Rollback

Revert the commits. Nothing is stored; the consent lives in memory only.
