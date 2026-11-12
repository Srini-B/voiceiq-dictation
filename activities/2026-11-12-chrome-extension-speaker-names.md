# 2026-11-12: Chrome extension names the speakers in browser meetings

## Why

VoiceiQ has no calendar integration, so a meeting's transcript knew the
far-side speakers only as Speaker 1, Speaker 2 unless their name tag was
read off the screen (OCR, which needs Screen Recording) or the notes model
heard someone introduce themselves. The VoiceiQ Meetings Chrome extension
already sat in the meeting page and knew when each participant was loud,
but it sent only anonymous stream ids. The maintainer asked for it to read the
active speaker's name from the meeting page, with when they started and
how long they talked, and for the app to use that to name speakers for
every transcription provider.

## What changed

1. **Extension 1.1.0.** While at least one remote audio source is loud,
   `page.js` reads the names on the tiles the page lights as talking
   (`SITES`: Google Meet, Teams, Zoom web, Jitsi Meet), leaves out the
   user's own tile, and sends them as `names` with the existing event.
   `relay.js` passes at most 16 names of up to 80 characters;
   `background.js` forwards them.
2. **`BrowserSpeakerEvent.names`** (optional, so old logs and the `hello`
   event decode as before).
3. **`BrowserSpeakers.name`** names far-side speakers in the finished
   transcript by how long each name was lit during their turns, and keeps
   when the name was first lit and for how long
   (`ScreenNames.Match.talkStart`, `talkSeconds`). `MeetingEngine.process`
   calls it after the screen names, so the names reach the Meetings window,
   Assign speakers and the notes request through `MeetingMeta.screenNames`.
4. **`BrowserSpeakers.apply`** uses the lit names as the timeline when the
   audio sources cannot tell people apart (one mixed stream, as on Zoom web)
   and two or more names were lit.
5. Settings footer, `docs/MEETINGS.md` and `docs/PRIVACY.md` now say the
   extension reads the names on lit tiles.

## Decisions

- **Names ride on the existing event**, not a separate "speaker, start,
  seconds" message. The event stream already carries the time every second
  while anyone talks, so start and total seconds are computed in the app
  from the same clock and tab as the sources, and a page closed mid-turn
  loses nothing.
- **Names only while a source is loud.** Zoom and Jitsi keep the last
  speaker's tile lit after they stop; without this gate silence would be
  named.
- **The app, not the extension, decides.** A name counts only when it was
  lit for at least half of a speaker's talk and more than twice as long as
  any other name, so the tile's one-second lag and a stale tile do not name
  the wrong person, and a site whose markup changed simply names nobody.
- **One step for every provider.** Naming runs on the saved transcript, so
  Gemini, OpenAI and ElevenLabs get it without provider code.
- **Names from the page win over OCR names** for the same speaker: they are
  exact text, not read off pixels.
- Left out: Whereby, Slack, Discord and Webex markup (no known talking
  mark), naming the owner from Meet's `data-self-name` (the owner already
  has the typed name, the owner marker and Settings), and a generic
  aria-label rule with no site known to use it.

## Verification

- Scratch Swift package on Linux (Swift 6.4.2) with
  `BrowserSpeakers`, `BrowserSpeakerLog`, `ScreenSpeakerNames` and
  `MeetingModels`: all 8 `BrowserSpeakersTests` pass, including the 2 new
  ones (`testSpeakersAreNamedByTheTilesThePageLitWhileTheyTalked`,
  `testNamesThePageLitSplitOneMixedStream`).
- Chrome for Testing 157 with the unpacked extension and a Python native
  host: fixture pages served as `meet.google.com`, `teams.microsoft.com`,
  `app.zoom.us` and `meet.jit.si`, each with that site's tile markup and a
  real WebRTC audio loopback. All four delivered the lit names in order,
  never the user's own tile or Teams' machine-id tile, and no names once the
  audio went silent with a tile still lit. The page path reached the host
  without its query string.
- The captured Zoom log through `save`, `apply` and `name` split one
  diarizer speaker into two and named both.

## Not verified

- Real Meet, Teams, Zoom or Jitsi calls. The selectors come from Vexa's
  open-source meeting bots and Jitsi's source; Meet's classes are
  obfuscated, and Teams' talking mark is unconfirmed even in Vexa.
- The macOS build and `scripts/test.sh`: these run in one combined Mac
  build with the ElevenLabs Scribe v3 and extension status changes.

## Rollback

Revert this change. Events with `names` still decode in an older build,
which ignores the field. An installed 1.1.0 extension keeps sending names
until Chrome reloads the older copy that the app reinstalls at launch.
