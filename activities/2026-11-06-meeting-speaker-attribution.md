# 2026-11-06: Each meeting line goes to the right person (Mac)

## Why

In every meeting, including Google Meet, Teams and Zoom in Chrome, each line
should go to the person who said it. On 2026-11-02 that failed in three
ways:

- `CallDetector` picked Superwhisper, which was recording at the same time,
  over Chrome. `ScreenNameSampler` then read names from Superwhisper's
  window.
- The system track was a global tap, so it recorded every app on the Mac.
- DeepInfra's Nemotron 3.5 Transcribe returned about 1 KB of plain text for
  each 240 s window, with no word times. Each whole window became one
  speaker.

The on-device diarizer also merged similar voices. Its replacement is in
`activities/2026-11-06-offline-speaker-diarizer.md`.

## What changed

1. **The meeting is locked to the call app.** A known call app or a meeting
   page now wins over an app that only looks like a call (`lookalike`).
   Superwhisper, Wispr Flow (`com.electron.wispr-flow`), MacWhisper and
   Granola joined `CallApps.notCalls`. `CallDetector.processes(for:)`
   returns `CallProcesses`: the Core Audio process objects of the app, its
   helpers and, for FaceTime and Phone, the call daemons, plus the call's
   input device. `SystemAudioTap` taps only those processes
   (`CATapDescription(stereoMixdownOfProcesses:)`), and `follow(processes:)`
   changes the tap description in place, with the same UUID. `MicTap`
   records the call's input device (`use(device:)`) and falls back to the
   default input. `MeetingEngine` resolves the processes again every 5 s
   while it records. With no call, the tap is global and the mic is the
   default input. `ScreenNameSampler` reads only the call app's own window
   (a meeting-titled window first, then on-screen, then the largest), never
   the whole display. With no call window it reads nothing.
2. **DeepInfra untimed words.** When a window's words have no times, or
   times past the end of the request (`MeetingTranscriber.timed`),
   `MeetingTranscriber` requests the window again as two halves
   (`halves`), down to 30 s (`shortestWindow`). The window cache moved to
   v7 (`cacheVersion`).
3. **The VoiceiQ Meetings Chrome extension** (`App/Resources/ChromeExtension`,
   Manifest V3, fixed ID `gjobkaplebdoedjfopfmogibphjmglaa`) reports which
   WebRTC source is loud and when. The native host is the existing
   `VoiceiQLocalSpeech` helper (`BrowserHostServer`), which appends the
   events to `~/Library/Application Support/VoiceiQ/browser-speakers/` through
   `BrowserSpeakerLog`. `BrowserSpeakers.save` copies the meeting tab's
   events to `browser-speakers.json` in the meeting folder, and
   `BrowserSpeakers.apply` relabels far-side words in both transcribers.
   Settings → Advanced → **Chrome extension for meetings** installs it.
4. **On-device speaker separation** is pyannote community-1 with an
   automatic speaker count (`docs/LOCAL_TRANSCRIPTION.md`).

The details are in `docs/MEETINGS.md`; what the extension reads and stores
is in `docs/PRIVACY.md`.

## Decisions

- **Overlap, not midpoint.** A far-side word goes to the source whose loud
  stretches overlap the word's time more than twice as much as any other
  source's. Other far-side words follow where most of their diarizer
  speaker's words went. The timeline is used only with at least 2 sources
  and at least 30 % of far-side words covered; otherwise the words stay as
  they were.
- **The tap follows the call in place.** `follow(processes:)` writes a new
  description onto the running tap, so the recording keeps one tap and one
  file while Chrome starts or restarts a helper.
- **Halves are billed again.** DeepInfra bills by audio length, so a window
  asked again in halves costs its audio twice (more for each further split).
  Only untimed windows are split, and on 2026-11-02 that was every window.
- Rejected: **manual speaker editing.** The user rejected it; every line
  must be right without the user fixing it.
- Rejected: **a localhost WebSocket** between the extension and the app.
  Native messaging was chosen instead. Chrome starts the host itself, only
  the extension ID in the host manifest's `allowed_origins` can connect, and
  no port is open on the Mac. The extension also works while VoiceiQ is not
  running.
- Rejected: **a separate native host target.** The speech helper already
  ships signed in the bundle, so it doubles as the host and the bundle has
  no second signed executable.
- Dropped: **the participant count from the call window** as an input to
  the diarizer. The benchmark showed it never helped as permission to find
  more speakers, and as a cap it hurt.
- Left out: **merging speakers across a channel change** (one person whose
  microphone changes mid-meeting can come out as two). A handoff between
  two similar voices could be merged by mistake.
- Dropped: **an offline writing model** for the notes. Only models of about
  5 GB follow the full rules prompt.

## Verification

All on the Mac mini with a notarized build.

1. **Call lock.** In a Chrome call, `afplay` played other speech at the
   same time. The meeting's system track matched the call clip's envelope
   at 0.998 and the other app's at 0.391; two unrelated clips match at
   0.30. The no-call fallback recorded all audio.
2. **DeepInfra halves.** Scratch tests on the Mac mini passed. Not run
   against DeepInfra: that Mac has no DeepInfra key.
3. **Chrome extension.** Chrome for Testing, a call with the Samantha and
   Karen voices, 10 turns. The diarizer alone gave one speaker. With the
   extension, all 10 turns went to the right person. Under an earlier
   midpoint rule, 6 words at turn edges went to the wrong person. The
   overlap rule fixes them, and
   `BrowserSpeakersTests.testWordsTheRecognizerTimesPastTheirTurnStillGoToTheirSpeaker`
   keeps them fixed.
4. **Speaker separation.** See
   `activities/2026-11-06-offline-speaker-diarizer.md`.

## Not verified

- A call that uses a mic other than the default. The Mac mini has one
  input.
- The halves against DeepInfra itself.
- Real Google Meet or Teams calls, where the extension reports contributing
  sources (CSRC).

## Rollback

Revert the commits of this change. The speaker model download replaced the
old `nemotron-3-diarization-offline` folder, so a rollback build downloads
Nemotron 3 Diarization again. A rollback build ignores `browser-speakers.json`
and the v7 window cache. An installed extension keeps starting the helper
from its host manifest, so remove it on Chrome's Extensions page and delete
`io.blue.voiceiq.browser.json` from each browser's `NativeMessagingHosts`
folder.
