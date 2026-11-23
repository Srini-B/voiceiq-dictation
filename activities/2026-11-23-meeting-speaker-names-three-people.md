# 2026-11-23: Speaker names in a three-person Meet call

## Why

A 22-minute Google Meet call in Chrome with three people, each on their own
laptop, came back with two speakers: "you" and "Speaker 1", where Speaker 1
was both remote people, and no names. The diagnosis
(thread T-01a20810-a361-7202-b644-d0f8ba7cdbf7) found five causes:

- Gemini gave both remote voices one id, and `MeetingTranscriber.place`
  carried that merge into every later window.
- The screen reader dropped the single-word name "Nihal" (likely; not
  confirmed) and the People button's count.
- `ScreenSpeakerNames.match` never names a name that is always on screen.
- About 114 s of far-side speech was labelled "you", and 49 s of mic speech
  was labelled Speaker 1.
- The Chrome extension never reported a speaker on Meet or Teams. Chrome also
  still ran the cached 1.0.0 service worker while `chrome://extensions` showed
  1.1.0.

The maintainer also asked for two things:

- The extension must update itself, with no manual reload.
- Settings must show the extension as missing once it is removed from Chrome.

## What changed

- **Extension 1.2.0.**
  - `page.js` counts a source as loud when its timestamps moved since the
    last poll, not by comparing clocks.
  - `page.js` sends Meet's roster, the user's own name and the head count.
    Every 10 s it also sends a diagnostic.
  - The worker is renamed to `service-worker.js`. It stamps every event with
    its version and reloads itself when the version on disk changes and no
    call is open.
- **Native host.** It stops when VoiceiQ's build number on disk changes.
- **Speaker count.** Taken from the roster or the People button
  (`ScreenSpeakerNames.expectedRemote`).
  - `place` no longer folds a new voice into the only known one when the call
    showed two or more other people.
  - The cloud path splits the far side with the on-device speaker model when
    that model is downloaded.
  - `ScreenNames.probablyMerged` and the notes request say when speakers are
    probably merged.
- **Screen names.** Steady single-word names and the roster now count. With
  one other person and one far-side speaker, that person's always-visible name
  is given to the speaker.
- **Words follow their track** (`MeetingTranscriber.byTrack`).
- **Settings.** The status reads each Chrome profile's `Secure Preferences`
  and `Preferences` (`BrowserExtensionInstalls`). It shows the install button
  again once the extension is removed.

## Decisions

- **An unknown speaker count keeps the old `place` rule.** A two-person call
  without the extension or a readable count still keeps one remote id across
  windows, as measured on 2026-09-27. The rule only fires when the reference
  clip got no label of its own, so no voice evidence contradicts it.
- **The diarizer split takes no forced speaker count.** The roster counts
  silent listeners, and forcing that many clusters would split one voice. The
  split is used only when the model hears more voices than Gemini gave ids.
- **The reload waits for a quiet minute.** `chrome.runtime.reload()` cuts off
  the content scripts of open tabs, so a reload during a call would lose that
  call's events.
- **The worker file was renamed instead of asking users to reload.** Only a
  new file name makes Chrome drop a stale cached worker at its next start.
- **Gemini dictation is unchanged.** The change affects meetings only.

## Verification

All checks ran in an orb with Chrome 157 for Testing and stand-ins for a Meet
page and the native host (scratch harness, not committed):

- A cached 1.0.0 worker survived three restarts while the manifest said
  1.1.0.
- The renamed worker ran after one restart.
- `chrome.runtime.reload()` swapped the worker at once.
- On a source clock 5 s behind the page:
  - Old `page.js` sent one event with `active: []`.
  - New `page.js` sent loud sources, Nihal lit, the roster `[Muhammed Hafeed,
    Nihal]`, `me: cyron`, `count: 3`, and `diag.clockOffset` 5003.
- Changing the version on disk during a call left the old version reporting.
  61 s after the call tab closed, the new version said hello through a newly
  started host.
- After the extension was removed, `Preferences` still held `{}` for it. That
  is why an entry needs `location` to count.

Swift tests use synthetic data:

- `ScreenSpeakerNamesTests`, `MeetingTracksTests`, `BrowserExtensionInstallsTests`
- `ChromeExtensionScriptTests`, which runs `page.js` and `service-worker.js`
  in JavaScriptCore
- A roster case in `BrowserSpeakersTests`

The JavaScript tests fail against the 1.1.0 `page.js`. A live Meet call could
not be tested.
