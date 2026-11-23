# Meetings on the Mac

How VoiceiQ notices a call, what audio it records, how each line goes to the
right person (Gemini's speaker labels, the VoiceiQ Meetings Chrome
extension, and names from the call screen), and how the Meetings window shows
and exports it. Meetings are transcribed by `gemini-3.5-transcribe` through
the Interactions API (`v1beta/interactions`), always from the saved tracks
after the recording stops; there is no live transcript while a meeting
records. Notes and meeting chat come from `gemini-3.8-flash`. With
Meetings set to On device, the tracks are transcribed and labelled by speaker
on this device instead ([ON_DEVICE.md](ON_DEVICE.md)). What is sent,
and the notes prompt, are covered in
[PRIVACY.md](PRIVACY.md) and [design/meeting-prompt-rulebook.md](design/meeting-prompt-rulebook.md).

## The transcription request

`GeminiClient.transcribeSpeakers` sends FLAC audio with a
`transcription_config` of `verbatim` mode, `diarization_mode: speaker` and
word timestamps (`timestamp_granularities: ["word"]`). Without the word
timestamps the API returned one text block with the speaker turns run
together (2026-09-26). A request tells apart up to 8 speakers and holds at
most 30 minutes of audio, so `MeetingTranscriber` sends only the stretches
with speech (`CallAudio.activeRegions`), cut into windows of 10 minutes of
speech each. Every window after the first starts with reference clips of the
speakers already found, so a speaker keeps one id across a long call
(`SpeakerLinker`). Finished windows are cached beside the audio, so a retry
never pays for the same audio twice.

## Call detection

`CallDetector` polls every 5 s (two hits on the same call to offer, three
misses to drop the offer) and reads which processes have running input and
output from Core Audio's process objects
(`kAudioHardwarePropertyProcessObjectList`, macOS 14.2+). A helper process is
mapped to its app with `responsibility_get_pid_responsible_for_pid`, and a
running app whose bundle sits inside another app's bundle (Chrome's "Google
Chrome Helper", Granola's "Granola Helper (MacOSMicAppsWithDevices)") stands
for that app: the app is what the lists match and what the offer names
(`CallDetector.containingApp`). It offers to record when one of these rules
matches. Rules 1 to 3 win over rule 4, whatever order the apps come in:

1. a system call daemon (`avconferenced`, `callservicesd`) captures the mic:
   FaceTime and iPhone calls relayed to the Mac, which have no app process on
   the mic. Shown as "FaceTime or phone";
2. an app in `CallApps.known` (Zoom, Teams, FaceTime, Phone, WhatsApp, Slack,
   Discord, Webex, Skype, Messages, Telegram, Signal, Viber, LINE, WeChat,
   Messenger, Chime, GoTo, RingCentral, Tencent Meeting, DingTalk, Around,
   Tuple, Element, Lark, Feishu, Pop, Zoho Meeting, Jitsi Meet, Gather, 8x8
   Work, Dialpad, Vonage Business, Wire, Threema, Threema Work, KakaoTalk,
   Zalo, Mattermost, Zoiper, Bria) captures the mic. Apps that also record
   voice notes (`CallApps.voiceNoteApps`: WhatsApp, Messages, Telegram,
   Signal, Viber, LINE, WeChat, Messenger, Lark, Feishu, Wire, Threema,
   KakaoTalk, Zalo, Mattermost) count only while they also play sound, so a
   voice note does not raise the offer. Each bundle ID added on 2026-11-17 was
   read from the vendor's installer or the App Store, not guessed; Whereby is
   browser-only;
3. a browser (`CallApps.browsers`, which includes Dia, Comet, Orion, Safari
   Technology Preview and Edge Beta, Dev and Canary, or any app named Chrome or
   Chromium) captures the mic on a page in `CallApps.meetingPages`, matched
   against window titles and the URL of each window's `AXWebArea` (searched 9
   levels deep, 300 elements at most, as FluidVoice does for Safari). The
   offer names the page's host ("meet.google.com"); a page found only by its
   title gets the name in `CallApps.meetingTitles` ("Google Meet");
4. a browser on any other page both captures the mic and plays sound, except
   the pages in `CallApps.notCallPages` (ChatGPT, Claude, Gemini, Chrome
   Remote Desktop). `CallDetector` keeps the first such browser as
   `lookalike` and returns it only when no app or page matches rules 2 and 3.

No other app is a call, however it uses the mic. Until 2026-11-17 rule 4
covered every app with two-way audio, and each new kind of app it caught
needed an exclusion: Jump Desktop Connect (2026-10-23), Superwhisper
(2026-11-02), and then Granola's helper and the Jump Desktop viewer, which
have their own bundle IDs and so missed the list
(`activities/2026-11-17-meeting-offer-only-for-call-apps.md`). Recorders,
dictation, remote desktop clients, and virtual machines all capture and play
sound, so the exclusion list could never be complete. A call app that is not
in `CallApps.known` gets no offer; Option-M still records it.

When a known app, a call daemon, or a meeting page is seen on two polls in a
row while the offer is for a tab that only looked like a call (rule 4), it
replaces the offer. A browser call is never replaced by a rule 4 tab of the
same browser: the page is read from the front tab, but the audio is the
whole browser's, so switching tabs during a call, on a meeting page or not,
is not a new call. The offer is dropped
after three polls without its call, even when another source shows on them,
so a call that ended gives way to the next one. A recording in progress
keeps its call.

Pressing × on the offer keeps that app, or that site in a browser, from
being offered again for 30 minutes (`MeetingEngine.dismissedQuiet`), so a
huddle that drops and is rejoined does not ask again. An offer that folds
away on its own after 30 s hides only that call. Option-M still records
during the quiet time. FluidVoice holds back a dismissed app the same way.

VoiceiQ's own processes never count.

**When the call ends (Mac).** A recording started from a detected call
watches for its end (`MeetingEngine.watchForCallEnd`, every 5 s). Once none
of the call's processes plays or captures sound
(`CallProcesses.isRunningAudio`) for 20 s, and neither track has carried
sound above about −40 dBFS for 45 s (`SoundClock`), the pill shows "Meeting
ended · Stopping in 30s" with Stop now and Keep recording. At zero the
recording stops and the notes are made as usual. The call coming back
cancels the countdown, and Keep recording holds until the call comes back
and ends again. A recording started without a detected call is never stopped automatically. The rules
follow FluidVoice's; a browser call ends only when the browser plays no
other sound.

**Calendar (Mac and iPhone).** With **Use calendar for meeting notes** on
(off by default; turning it on asks for calendar access), a recording takes
the calendar event it falls in: an event that started before it or starts
within 10 minutes, not all-day, cancelled, free or declined, with other
people invited or a Zoom, Meet, Teams, Webex or Slack link
(`CalendarMeetings.event(at:)`). Its title shows in the list until the notes
have one, and the notes request gets the title and up to 30 invitees' names
for the title and name spellings (`MeetingMeta.calendarEvent`). Hex reads
the calendar the same way.

**Next meeting (Mac and iPhone).** With the calendar connected, the next
meeting by the same rules, up to a week ahead, shows at the top of Meetings
on the Mac (`NextMeetingCard`, above Record), at the top of Notes on iPhone and iPad
(`NextMeetingSection`), and in the Mac menu-bar menu under the status line.
It shows the title and when it starts ("in 12 min" within the hour, else
the time, "Tomorrow 10:00 AM" or "Wed 10:00 AM"). One that started up to 10
minutes ago still shows, as "Now", so a late joiner can still join it. When
the invite's link, location or notes hold a Zoom, Google Meet, Teams or Webex
https link, a button joins it; Slack links are not offered, since an
invite's slack.com link is rarely the call. On the Mac the button and the
menu item are **Join Zoom and Record**: they start a recording, then open the
link (`MeetingEngine.join`), so the call is recorded from its first second;
already recording, they only open the link. The recording takes the joined
event's title and invitees (`Upcoming.event`), not whatever event the clock
falls in, so a meeting joined early is still named right. It has no call source,
even when another call is detected at that moment: it records all system
audio, and like any recording started without a detected call it is not
stopped automatically when the call ends. On iPhone it
is **Join Zoom** alone, since the phone cannot record calls.
The screens refresh every 30 seconds and whenever the calendar changes
(`NextMeetingModel`); the menu reads the calendar each time it opens
(`CalendarMeetings.next(after:)`). With the calendar off or access denied,
nothing shows.

WebKit's XPC services (`com.apple.WebKit.*`, such as "Safari Graphics and
Media") are skipped. macOS lists them as running apps, and Safari's GPU
process captures the mic itself, so it used to win before Safari and the
call was recorded as an app with no windows. Safari is found through the
helper's responsible process instead, and its Meet page is read as usual.

Before macOS 14.2 only rules 2 and 3 apply, on the global "mic in use" bit.

The daemon names in rule 1 come from Apple's process layout; a relayed
iPhone call was not available to test on the development Mac.

## What a meeting records

A meeting folder holds two tracks: `mic.caf` and `system.caf`. On a detected
call, both come from the call alone. When the recording starts,
`CallDetector.processes(for:)` returns the call's `CallProcesses`:

- `objects`: the Core Audio process objects of the call app, of every helper
  it is responsible for (Chrome's audio service, Safari's WebKit GPU
  process) or whose executable sits inside the app's bundle, and, for FaceTime and Phone (`CallApps.daemonCallApps`), of the
  call daemons that carry the audio.
- `inputDevice`: the input device that the first of those processes with
  running input captures.

`SystemAudioTap` taps only those processes
(`CATapDescription(stereoMixdownOfProcesses:)`). The tap takes their sound
before it reaches an output device, so music, notifications, and other apps
stay out of `system.caf`, and the speakers or headphones the call plays to
make no difference. `MicTap` records `inputDevice` (`MicTap(url:device:)`).
If that device fails to start, or fails after its retries later on, it
records the default input instead, and `MicTap.use(device:)` ignores that
device for 60 s (`failedBackoff`), so a call that keeps reporting it does not
stop the default every 5 s.

While the meeting records, `MeetingEngine.follow` resolves the processes
again every 5 s. `SystemAudioTap.follow(processes:)` writes a new tap
description with the same UUID onto the running tap when the set changed,
for example when Chrome restarts its audio service mid-call. `MicTap.use(device:)`
moves the mic track when the call moves to another input.

With no call detected (a recording started by hand), or when none of the
call app's processes has audio open at the start, `system.caf` is a global
tap of all system audio and `mic.caf` records the default input. Nothing
follows the call then. Before macOS 14.2 there is no process list, and
`processes(for:)` returns nil.

A call in a browser is tapped as the browser's processes, and Chrome plays
every tab through one audio service. Sound from another tab of the same
browser (a video, say) is in `system.caf` with the call. Core Audio has no
per-tab process, so this is not fixable at the tap.

Measured on the Mac mini with a notarized build: during a call in Chrome,
`afplay` played other speech. The sound envelope of `system.caf` matched the
call clip at 0.998 and the other speech at 0.391. Two unrelated clips match
at about 0.30. With no call detected, the recording held all the audio. A
call that uses a mic other than the default was not tested, because the Mac
mini has one input. The decisions are in
[activities/2026-11-06-meeting-speaker-attribution.md](../activities/2026-11-06-meeting-speaker-attribution.md).

## The note owner

The owner is the speaker heard from the mic and not from the far side
(`MeetingTranscriber.markOwner`). This runs only when the recording is a call
(`CallAudio.isOnline`): at least 5 s of far-side speech when the recording
started on a detected call (`MeetingMeta.source`), and 20 s otherwise.
Before 2026-10-27 every recording needed 20 s. A 2.5-minute Meet call had
15.9 s, so the owner became an ordinary speaker and got a participant's name
from the screen.

## Speakers in browser calls from the Chrome extension

In a browser call, everyone on the far side arrives in one audio track, and
the diarizer can merge two people who sound alike. The VoiceiQ Meetings
extension for Chrome reports which of the call's WebRTC audio sources is loud,
and when. Each source is one participant, so the extension tells people
apart however alike they sound. While a source is loud it also reports the
names on the tiles the meeting page lights as talking, which name the
speakers. It reads no audio and no other page text. What it reports and
where that is kept is in [PRIVACY.md](PRIVACY.md).

Everything here runs after Gemini's transcript is back, on its
speaker-labelled words.

### What the extension reports

The extension is in `App/Resources/ChromeExtension` (Manifest V3, Chrome 116
or later). Its manifest `key` fixes the extension ID at
`gjobkaplebdoedjfopfmogibphjmglaa`, so the native host manifest can name it.
The only permission is `nativeMessaging`. Its content scripts run at
`document_start`, in every frame, on Google Meet, Teams
(`teams.microsoft.com`, `teams.live.com`, `teams.cloud.microsoft`), Zoom
(`*.zoom.us`, `*.zoom.com`), Jitsi Meet (`meet.jit.si`), Whereby, Slack,
Discord, and Webex.

- `page.js` runs in the page's MAIN world, before the page's own scripts. It
  replaces `RTCPeerConnection` with a subclass that keeps each connection.
  Every 250 ms it reads the sources of each live remote audio receiver. It
  uses the contributing sources (CSRC) when the receiver has them: Meet and
  Teams mix people into a few streams and mark each person with a CSRC.
  Otherwise it uses the synchronization sources (SSRC), one stream per
  person. A source is loud when its `audioLevel` was at least 0.01 (about
  -40 dBov) within the last 400 ms. The script posts the sorted loud ids
  (such as `csrc:3141` or `ssrc:2718`) with the time and the page's host and
  path. It posts when the list changes, and every 1 s while the list is not
  empty, so a pause in the call differs from a page that stopped reporting.
- While at least one source is loud, `page.js` also reads `names`: the name
  on each tile the page lights as talking, from the site's entry in `SITES`.
  It leaves out the user's own tile, and it reads nothing while every source
  is quiet, because Zoom and Jitsi keep the last speaker lit after they stop.
  A change of names is posted like a change of sources.

  | Site | Tiles | Lit as talking | Name | Own tile |
  | --- | --- | --- | --- | --- |
  | Google Meet | `[data-participant-id]` | class `Oaajhc`, `HX2H7`, `wEsLMd` or `OgVli` on the tile or inside it | `span.notranslate` | has `[data-self-name]` |
  | Teams | `[data-stream-type][data-tid]` | its `[data-tid="voice-level-stream-outline"]` has `vdi-frame-occlusion` | the tile's `data-tid`, unless it looks like a machine id (`video-stream-2`, `videoTile`) | not detected |
  | Zoom web | the active-speaker frame (`.speaker-active-container__video-frame` and the `single-…-container__video-frame` family) | always | `.video-avatar__avatar-footer` | not detected |
  | Jitsi Meet | `.videocontainer.dominant-speaker` | always | `.displayname` | id `localVideoContainer…` |

  Whereby, Slack, Discord and Webex report sources only. The selectors are
  the services' own markup, taken from Vexa's open-source meeting bots
  (Meet, Teams, Zoom) and Jitsi's source; Meet's classes are obfuscated and
  Teams' speaking mark is unconfirmed even there. A service that changes its
  markup usually gives no names rather than wrong ones, and a name is used
  only where it agrees with the transcript's timing (see below).
- `relay.js` runs in the content script world and passes on only messages
  of that shape: a numeric time, a page cut to 300 characters, at most 64
  ids of up to 40 characters each, and at most 16 names of up to 80.
- `background.js` adds the tab id and sends each event to the native
  messaging host `io.blue.voiceiq.browser`. When the host cannot be reached,
  it waits 30 s before it connects again. On install and at browser start it
  sends a `hello` event (tab `-1`), so Settings can show that the extension
  works.

### The native host

The host is the `VoiceiQLocalSpeech` helper. It ran the on-device speech
models until 2026-11-10 and keeps its name and bundle id, because installed
host manifests point at it; it now links only `VoiceIQSpeech`. Chrome starts it with the extension's origin as
the first argument, and `BrowserHostServer.isBrowserLaunch` sends that launch
to `BrowserHostServer.run`. The host reads length-prefixed JSON messages of up
to 64 KB from stdin. `BrowserSpeakerLog.append` writes each event as one JSON
line to `~/Library/Application Support/VoiceiQ/browser-speakers/<UTC day>.jsonl`.
VoiceiQ does not need to run while the extension reports.

### How the events label the words

1. `MeetingEngine.stopRecording` calls `BrowserSpeakers.save`. It reads the
   events from 5 s before the meeting started to 5 s after it ended, groups
   them by tab and page, and keeps the tabs where a source was loud. It takes
   the tab on the detected meeting page, else the busiest one, and writes its
   events to `browser-speakers.json` in the meeting folder, where Retry and
   Redo find them. A call in a known call app (`CallApps.known`, Zoom or
   FaceTime, say) gets no timeline, because any browser tab is another call.
   An app detected only because it looks like a call keeps the fallback: it
   can be a Chromium browser that `CallApps.browsers` does not list. A recording that
   was interrupted gets its timeline at the next launch
   (`MeetingEngine.failInterruptedRecordings`), up to the last write to its
   tracks. `save` then calls `BrowserSpeakerLog.prune`, which deletes day
   files older than 7 days. The native host prunes the same way when Chrome
   starts it and then hourly, so the log is pruned even when no meeting is
   recorded.
2. Each event lasts until the next one, for at most 3 s (`hold`), widened by
   0.3 s on each side (`slack`). These are each source's loud stretches.
3. `BrowserSpeakers.apply` runs before turns are built, in
   `MeetingTranscriber`. The owner's words stay `you`.
4. A far-side word goes to the source whose loud stretches overlap the
   word's time more than twice as much as any other source's. The rule uses
   overlap, not the word's midpoint, because the recognizer often starts a
   word early or stretches a turn's last word over the silence after it.
5. A far-side word with no such source goes where most of its diarizer
   speaker's words went, weighted by word length.
6. The speakers are renumbered `s1`, `s2`, and so on, in order of first
   appearance. Screen names are matched to them afterwards as usual.

The words stay as they were unless the timeline has at least 2 sources and
covers at least 30 % of the far-side words. One source means a call with one
other person, or a service that sends everyone in one stream with no CSRCs,
and the diarizer knows those better. Too little coverage means the timeline
is from another call. When every source is a stream id (`ssrc:`), at least
one must be loud again after another source was (`tellsPeopleApart`): a
mixed stream that reconnects comes back under a new id, so its ids follow
one another and none returns. Only events with one loud stream count, because
the old and new stream can both be loud for a moment.

When the sources do not tell people apart but the page lit two or more
names (Zoom web, which sends everyone on one stream), the lit names stand in
for the sources in steps 2 to 6 (`BrowserSpeakers.byName`). The same 30 %
coverage rule applies. Tiles trail the voices, so on this path the words in
the first 1.5 s of a diarizer turn (`BrowserSpeakers.tileLag`) take the name
heard first after that stretch (`BrowserSpeakers.steadied`), or none when
the turn ends before then, so a short turn follows the diarizer; a later
change of name within one turn still splits it.

### How the names name the speakers

`MeetingEngine.process` calls `BrowserSpeakers.name` once the transcript is
saved, after the screen names are matched, and on every Retry or Redo:

1. Each name's lit stretches are built as in step 2 above, from the events'
   `names`, and joined where they overlap.
2. For each far-side speaker in the transcript, it adds up how long each
   name was lit during that speaker's turns.
3. A speaker takes a name that was lit for at least half of their talk and
   more than twice as long as any other name. The tile lights about a second
   after the voice starts and can stay lit into the next turn, so the rule
   uses overlap over whole turns and skips the first 1.5 s after the
   speaker changes (`BrowserSpeakers.tileLag`), across every segment of
   that turn.
4. A name goes to one speaker only, the one it overlaps most. It replaces a
   name read off the screen for that speaker, and the screen's match is
   dropped wherever it gave that name to someone else.
5. Each match keeps when the page first lit the name (`talkStart`, seconds
   from the start of the recording) and how long it was lit in all
   (`talkSeconds`), counting only time after the recording started; `seen` and `of` hold the overlap and the speaker's talk
   in seconds. They are stored in `MeetingMeta.screenNames`, so the
   Meetings window, Assign speakers and the notes request use them like
   screen names. Every lit name also goes to the front of `seen`, longest
   first, so the notes model knows the participants.

The owner's words are never named this way; their name comes from the
owner marker, the typed name or Settings, as before.

### Install the extension

The extension is not on the Chrome Web Store. Chrome 137 removed
`--load-extension`, and on a Mac an extension from outside the store installs
only through MDM, so you load it once as an unpacked extension.

1. In Settings → Advanced → **Chrome extension for meetings**
   (`BrowserExtensionSection`), click **Install in Chrome…**.
   VoiceiQ copies the extension to
   `~/Library/Application Support/VoiceiQ/ChromeExtension`. It writes the host
   manifest `io.blue.voiceiq.browser.json` into the `NativeMessagingHosts`
   folder of each Chromium browser that has a support folder: Chrome, Chrome
   Beta, Chrome Canary, Chrome for Testing, Chromium, Edge, Brave, Arc, and
   Vivaldi. Then it opens `chrome://extensions` in Chrome and selects the
   folder in Finder.
2. On the Extensions page, turn on **Developer mode**.
3. Drag the `ChromeExtension` folder onto the page, or click **Load unpacked**
   and choose it.

At each launch, VoiceiQ copies the files and writes the host manifests again
when the extension is installed (`BrowserExtension.refreshIfInstalled`), so
both follow app updates. **Status** shows "Not installed", "Waiting for
Chrome to load it", or "Last heard from it" with the time of the newest
write to the log. The native host, not the app, writes that log, so the row
reads it again every second while Settings is open: it turns to "Last heard"
as soon as Chrome loads the extension and sends its first event. It does not
claim the extension works now: a disabled extension leaves the old log behind.

### Measured

On the Mac mini, with a notarized build and Chrome for Testing, a call with
two similar voices (Samantha and Karen, 10 turns): the diarizer alone found
one speaker. With the extension, all 10 turns went to the right person. An
earlier rule that used each word's midpoint put 6 words at turn edges on the
wrong person. The overlap rule puts them right
(`BrowserSpeakersTests.testWordsTheRecognizerTimesPastTheirTurnStillGoToTheirSpeaker`).
Real Google Meet and Teams calls, which use the CSRC path, were not tested.

Names, 2026-11-12, on Linux with Chrome for Testing 157 and the unpacked
extension: fixture pages served as `meet.google.com`, `teams.microsoft.com`,
`app.zoom.us` and `meet.jit.si` built each site's tiles as in the table
above, ran a real WebRTC audio loopback, lit Priya's tile for 3.5 s and then
Max's, then went silent with Max still lit. On all four, the native host
received Priya's name with the first loud event, Max's within 250 ms of the
switch, and no names once the audio stopped; the user's own tile and Teams'
`video-stream-2` tile never appeared. The Zoom log, put through `save`,
`apply` and `name`, split one diarizer speaker into Priya and Max and named
both. No real Meet, Teams, Zoom or Jitsi call has been tested, so whether
those services still use this markup is not known.

## Speaker names from the screen

Call apps show the active speaker's name tag on their tile. VoiceiQ reads those
tags while it records and matches them to the diarized speakers afterwards.

This always runs while a meeting records; it has no setting, and it adds no
time to dictation. It uses Screen Recording when it was granted (the
onboarding asks for it, and it is optional), and the call window's text
through Accessibility, which VoiceiQ already has. Either one is enough. A
meeting never raises a permission prompt (`CGPreflightScreenCaptureAccess`,
`AXIsProcessTrusted`).

1. `MeetingEngine.startRecording` starts a `ScreenNameSampler` with the
   detected call source. A recording started by hand with no call detected
   reads the frontmost known call app (`ScreenNameSampler.frontCallApp`).
   With no call app, the sampler does not run.
2. With Screen Recording granted, every 3 s the sampler captures one window of the call app or browser
   with ScreenCaptureKit (`SCContentFilter(desktopIndependentWindow:)`, so it
   works when the window is covered). It picks a window whose title names a
   page in `CallApps.meetingPages` first, then a window on screen, then the
   largest. A browser with no such window gives no image, because its other
   windows are other pages. It never captures the whole display, because other apps' windows
   (a dictation app, a chat, a document) hold names that are not the
   meeting's. When the call app has no window to read, the sample has no
   image. The long side is capped at 2560 px.
3. Vision reads the text of the whole frame and of four overlapping quarters
   (name tags are small). `ScreenSpeakerNames.candidates(in:)` keeps lines that
   look like name tags: two to four capitalised words, or one word followed by
   `-`, `–`, `|` or `(`.
4. The image is dropped as soon as it is read. **No screenshot is ever written
   to disk**, so there is nothing to clean up. Only `(time, names)` samples are
   kept, and `stopRecording` saves them as `screen-names.json` in the meeting
   folder. Snapshots with no names are kept too; they set the base rate.
5. With Accessibility granted, `CallWindowText` also reads the call app's
   windows through the Accessibility API at each sample: static text, image
   and group labels (name tags, the participants list), not buttons or menus.
   The walk stops at 2,500 elements or 0.8 s, because each read waits on the
   call app. Electron and Chromium apps are woken first with
   `AccessibilityWaker`. Either permission is enough for sampling to run.
   Zoom 7.2 exposes each video tile as an `AXTabGroup` described "Name,
   Computer audio unmuted", and the participants list as `AXStaticText`
   rows such as "Name (me)".
6. Lines the call app marks as the user's own ("Priya Raman (me)", Zoom's
   "(Host, me)", Meet's and Teams' "(You)") are kept as `me` on the sample
   (`ScreenSpeakerNames.owner(in:)`).
7. After transcription, `ScreenSpeakerNames.match(samples:transcript:)` runs
   (also on Retry, from the saved file):
   - Spellings within 0.8 Levenshtein similarity fold into the most frequent one.
   - For each speaker other than "you", it counts snapshots taken while only
     that speaker talked (1 s lag for the tile switch).
   - A name wins a speaker when it is in ≥50 % of those snapshots, ≥1.5× its
     overall rate, and ≥2 snapshots. Pairs are assigned greedily by
     lift × count; a name goes to one speaker only.
   - The 30 most frequent names go to `ScreenNames.seen`.
   - "you" is named only from the owner marker, when one name carries it in
     at least two samples. Active-speaker views never show the user their own
     tile, so a name on screen while the user talks is someone else's.
   The result is stored as `MeetingMeta.screenNames`.
8. The notes prompt labels matched speakers with their screen name and lists
   `seen`; the notes model returns `participants`, the people among them.

Name shown for a speaker (`MeetingMeta.displayName`): the name the user typed,
then the screen match (where the Chrome extension's name, when it has one,
has replaced what was read off the screen), then the notes model's
suggestion, then "Speaker N".
`MeetingMeta.knownNames` lists every name from those sources for Assign speakers.

Limits: a gallery view with every tile always visible gives no signal (a name
that is always on screen has no lift); banners covering a tag lose it; the
owner is named only when the call app marks their tile or row.

## The notes request

`MeetingNotesPrompt.build` writes the request; its rules and sources are in
docs/design/meeting-prompt-rulebook.md. Fixes from 2026-10-29:

- **Output language.** `NLLanguageRecognizer` names the transcript's main
  language when it is at least 60 % sure, and the request says
  `OUTPUT LANGUAGE: English`. An all-English meeting had come back in Hindi
  once, and in English on a redo of the byte-identical request.
- **The owner by name.** Notes are shared, so the owner is never "You" in
  them. The owner's label is, in order: the name typed for that meeting, the
  owner marker on screen, **Your name in meeting notes** in Settings →
  Dictation (`SettingsStore.meetingOwnerName`, key `meetingOwnerName`; the Mac
  defaults to the account's full name), else "Note owner". The rules forbid
  "you" for any participant.
- **One spelling per name and term.** The request carries the user's
  Dictionary (vocabulary and spellings) and custom writing rules, as a
  dictation does. The model fills a leading `glossary` field first: one entry per
  person, product and term, with every transcript spelling that means it
  (`"Nitin": ["Nithin", "Lithin", "Nathan"]`). Every other field uses those
  spellings. `MeetingNotes` ignores the field when decoding.
- **Dictionary spellings in the transcript.** Google takes no custom
  vocabulary together with diarization, so the transcript is heard verbatim.
  The Dictionary's wrong → right spellings (`ReplacementEngine`) are then
  applied to every segment before it is saved
  (`MeetingEngine.corrected`), as they are to a dictation, so the saved
  transcript, the notes and the chat all read the corrected words. Speakers
  and timestamps are unchanged.
- **No delete while busy.** A meeting that is recording, transcribing or
  writing notes can't be deleted, on the Mac (the More menu is disabled)
  or on iPhone (no swipe to delete), so its Gemini calls never run on with
  nowhere to save.

## Redo and progress

- **Redo notes** writes the notes again from the saved transcript.
- **Redo transcript and notes** (`MeetingEngine.retry(id:fresh: true)`) drops
  the cached words (`transcribe-*`, and `local-words-*` and `speakers-*` from
  builds before 2026-11-10) and hears
  the whole meeting again. `browser-speakers.json` stays. **Retry** after a
  failure keeps the finished windows.
- Redo and Retry transcribe from the saved tracks with the meeting model set
  at that moment (Settings → Advanced → Meeting model). `mic.caf` and
  `system.caf` stay until the meeting is deleted; the audio retention setting
  applies to dictations only.
- `MeetingEngine.processing` maps each meeting being processed to its step
  (`.transcribing` or `.summarizing`). The Mac header shows a spinner with
  "Transcribing" or "Making notes" while old notes stay on screen; iOS shows
  the same step as a card above the notes.

## Play and Download

Every meeting and dictation detail has Play and Download for its audio, on
the Mac (icon buttons in the header) and on iPhone (an Audio card). Both are
disabled when the audio is not on the device: a dictation synced from the
other device or removed by audio retention, or a meeting still recording.
Redo transcript and notes is disabled the same way.

`RecordedAudio` (VoiceIQCore, `Support/RecordedAudio.swift`) makes one AAC
`.m4a` per recording in its folder's `playback/` folder and both buttons use
it. Deleting the recording, or its audio by retention or "never keep audio",
removes the copy too; copies 0.7.1 (75) left in the temporary folder are
deleted at launch. A
dictation is its `audio.caf`. A meeting is `mic.caf` and `system.caf` mixed
as `CallAudio.samples` hears them: each track levelled to about -20 dBFS and
the raw mic ducked while the far side talks. It never reads or writes
`mic-aec.caf`, so it can run while the transcriber is echo-cancelling.
`RecordingPlayer` plays the file; on iPhone, outside a voice session, it takes
a `.playback` session so the silent switch does not mute it. Download on the
Mac copies the file to Downloads and shows the export message; on iPhone it
is a share sheet, so Save to Files keeps it.

## The pill in screen shares

The pill shows the recording clock while a meeting records. When you share
your whole screen, the other people would see it. **Hide pill from screen
sharing** in Settings → Dictation (`SettingsStore.hidePillFromScreenSharing`,
key `hidePillFromScreenSharing`, default on) keeps it out of other apps'
captures. You still see it on your Mac.

`PillHUDController` sets the panel's `sharingType` to `.none` (off:
`.readOnly`). The setting applies to every pill state, not only meetings.
Apple calls `sharingType` a legacy value and gives no guarantee that capture
apps honour it. Reports from macOS 15.4 said ScreenCaptureKit captured such
windows. On macOS 26.6.2 (2026-10-27), a ScreenCaptureKit display stream and
screenshot from another process left the pill out. Zoom, Meet and Teams
were not tested directly. A camera pointed at the screen, or a
mirrored or AirPlay display, still shows the pill.

## Meetings window

`App/Sources/Windows/`:

| File | Shows |
| --- | --- |
| `MeetingsView.swift` | Record button and folder menu above the list, each row's folders, the folder line under the title ([Folders](#folders)), the detail header (title, progress while transcribing or making notes, Update notes after a speaker is renamed, Play and Download audio (`RecordingAudioButtons.swift`), Export menu, `…` menu with Redo notes / Redo transcript and notes / Retry / Delete, transcript toggle), the export message |
| `MeetingNotesColumn.swift` | Title, Summary, the meeting type's sections, Decisions, Action items as open circles ("Owner: task"), Notes, then the meeting's questions and answers (`MeetingChatView.swift`, which also has the question box `MeetingsView.swift` puts under both columns) |
| `MeetingTranscriptColumn.swift` | The transcript in one `NSTextView`: speaker names in their own colour (`SpeakerPalette`), time on a right tab stop, search that filters and highlights |
| `AssignSpeakersView.swift` | One card per speaker: name, a sample line, shuffle (next line), play (that line's audio) |

In Assign speakers, clicking a name lists `knownNames`, a field for another
name, and Reset when the user typed one. The notes keep the names they were
written with (`MeetingMeta.notesSpeakerNames`). When a name is set, changed
or cleared after that (`namesChangedSinceNotes`), the header shows **Update
notes**, which runs `MeetingEngine.regenerateNotes` with the typed names. A
name typed while the notes are written is kept and shows the button again. Play uses `mic-aec.caf` (else
`mic.caf`) for "you" and `system.caf` for everyone else, from the turn's start
to its end, through `AVAudioPlayer`.

## Folders

Folders file meetings like tags: a meeting can be in several, and deleting a
folder never deletes a meeting. The Mac and the iPhone use the same model and
menus (`MeetingFolderModel`, `MeetingFolderToggles`, `MeetingFolderFilterItems`
and `meetingFolderEditing` in `VoiceIQCore/Sources/MeetingEngine/MeetingFolderViews.swift`):

- **Show one folder.** The menu above the list (Mac) or the folder button in
  the toolbar (iPhone and iPad) picks All meetings or one folder, and makes,
  renames, or deletes the folder shown. Deleting asks first and says the
  meetings stay.
- **File a meeting.** The folder line under the meeting's title (Mac), the
  folder button on an open note (iPhone and iPad), the folder button that
  appears on the row under the pointer (Mac), or a right-click or long press
  on a row lists every folder with a check mark, then New Folder…, which
  makes the folder and files the meeting in it. On iPhone and iPad a swipe
  right on a row offers Folders, which opens the same list as a sheet
  (`MeetingFolderPicker`). Filing works while a meeting is still being
  transcribed. Imported meetings (Granola) start in no folder.
- **See a meeting's folders.** Each row and each open meeting shows its
  folders by name.

The store API (`MeetingFolders.swift`, an extension on `MeetingStore`):
`folders()`, `createFolder(named:)` (returns the existing folder when the name
matches in any case, so an import run twice files into the same folders),
`renameFolder(_:to:)`, `deleteFolder(_:)`, `folderIDs(of:)`,
`setFolderIDs(_:for:)` and `setMeeting(_:inFolder:_:)`. An importer creates its
meetings first, then calls `createFolder(named:)` and `setFolderIDs(_:for:)`.

On disk:

- `meetings/folders.json` holds the list (`MeetingFoldersSnapshot`): each
  folder's id, name, and creation and edit times; when each deleted folder was
  deleted (kept 180 days, as the dictionary keeps its deletions); and
  `aliases`, folders that became another (below).
- `meetings/<meeting>/folder-ids.json` holds the ids of the folders the meeting
  is in, apart from `meta.json`, so the engine's saves of a meeting it is
  transcribing never drop a folder chosen meanwhile. No file means no folder.
  A deleted folder's id stays in the file and is skipped: removing it would
  send every meeting in it to iCloud again.

Two folders with one name (any case), made apart on two devices or by a
rename, become the older one. The newer id goes in `aliases`, and meetings
filed in it count as filed in the survivor, so none has to be written or sent
again.

## Asking about a meeting

Once a meeting has a transcript, a question box sits along its bottom
(macOS: under both columns, so it stays while the transcript is open; in a
narrow window, sending switches back to the notes, where the answers are
listed after the Notes section. iOS: pinned to the bottom of the note, with
the answers after the notes). A question
goes to Gemini's dictation model (`gemini-3.8-flash` unless Settings →
Advanced → Dictation model names another).
`MeetingChat` builds the request:

- **System prompt.** Short answering rules, then the meeting as
  `MeetingStore.markdown(id:parts: .both)` builds it for Export: notes above
  the transcript, with speaker names and times. It is rebuilt for each
  question, so renamed speakers and redone notes are used from the next one.
- **Turns.** Every earlier question and answer, in order, then the new
  question. The model sees its own earlier answers, so follow-ups work.

It is sent with `GeminiClient.chat` (`generateContent`). Gemini caches the
repeated prefix implicitly; nothing extra is sent. Gemini 3.x caches only
from 4,096 tokens, so a short meeting is not cached.

Each answered question is saved with its answer, time and model in
`chat.json` in the meeting's folder (`MeetingStore.loadChat` /
`save(chat:id:)`), and the chat is there when the meeting is opened again. A
question that fails is not saved; the chat shows the error with Try again.
`MeetingChatModel.shared` keeps one chat per meeting while the app runs, so
leaving a meeting while a question is out and coming back shows it still
waiting. Usage is booked as Meetings › Meeting chat against the meeting.
Deleting the meeting deletes its chat. With meeting sync on, a chat model
on screen reloads when questions asked on the other device arrive, and an
answer that lands is appended to the chat as it is on disk then, so neither
device's questions are lost.

## Sync through iCloud

Meetings are the same on the Mac and the iPhone, with no setting, like
History and the dictionary. Both Privacy pages list it under what leaves
the device. `MeetingSync`
(VoiceIQCore) works like `HistorySync` (see IOS.md, History sync): one
`Meeting` record per meeting in the `Meetings` zone of the same private
CloudKit database, through `CKSyncEngine`.

- **What goes.** A record's one field, `payload` (Bytes), is a
  `SyncedMeeting` as LZFSE-compressed JSON: `meta.json`, `notes.json`,
  `transcript.json` and `chat.json`. The audio, screen-name snapshots,
  transcription caches and playback files stay on the device that recorded.
  A record holds at most 1 MB; a meeting whose compressed payload is over
  900 KB is logged and stays local (several hours of talk is a few hundred
  KB). A meeting that arrives but cannot be written (a full disk) leaves no
  partial folder; its id waits in `.sync/retry.json` and it is fetched
  again by id when sync starts and after every fetch. An update that
  fails partway waits there too: it is not sent as a local edit, and the
  copy fetched again replaces it whole.
- **When.** A meeting goes up once its status is `done`, and again whenever
  it changes: renamed speakers, redone notes, a new question.
  `MeetingStore` posts `.gtMeetingsDidChange` for every write and delete;
  `MeetingSync` compares the meeting's content digest with the one in its
  `cloud.json` (`MeetingCloudState`: digest, the record's system fields,
  and whether it arrived from another device) and queues a save when they
  differ. A meeting being recorded or redone waits until it is done again.
- **Both devices changed it.** A device with no change since it last synced
  takes the other device's copy as it is. A device with its own change keeps
  its notes, transcript and names, adds the questions asked on the other
  device (each once, in the order they were asked), and sends that over the
  copy in iCloud (`MeetingStore.applyFromCloud`). So the device that sends
  last wins the notes and names, and no question is lost.
- **On the other device.** A meeting from another device opens like any
  other: notes, transcript, speaker names, Export and questions all work.
  Play, Download and Redo transcript are unavailable because the audio is not
  there; Redo notes works from the transcript.
- **Deletes.** Deleting a meeting deletes its record in iCloud, and the
  other device removes its copy. Every delete is sent, because a first
  upload may be on its way while a Redo has the meeting unfinished again;
  a record that never went up answers "unknown item", which counts as gone. The id waits in
  `.sync/deletes.json` in the meetings folder until iCloud confirms the
  record gone, so a delete made before sync started (or before the engine
  saved its state) is still sent, and a copy fetched meanwhile does not
  bring the meeting back. A
  delete from another device wins over an edit here that has not gone up
  yet: the queued save is dropped. A save answered with "unknown item" is
  held back (`.sync/held.json`), through edits and relaunches, until a
  fetch that started after it finishes: if that fetch brings the delete,
  the meeting goes; if not (the zone was made again), it goes up as a new
  record. The local meeting and its recording are never removed on that
  answer alone. A note open on the iPhone when it is
  deleted elsewhere closes.
  Retention never deletes meetings.
- **Account changes.** Signing out of iCloud, switching accounts, or a deleted zone removes the meetings that
  came from another device and forgets which local ones were sent.
- **Folders.** The folders a meeting is in travel in its record
  (`SyncedMeeting.folderIDs`; absent for a meeting in none, so meetings filed
  nowhere keep the digest they had and are not sent again). The two-device rule
  above applies: the device that sends last keeps its folders for that
  meeting. The folder list itself syncs through the iCloud key-value store, as
  one value, `meetingFolders.v1` (`MeetingFolderSync`), merged per folder like
  the dictionary: the newer edit wins and a delete wins over older edits. That
  needs no new CloudKit record type, which would need a schema deploy. A build
  older than folders keeps a meeting's folders as it found them but drops them
  when it changes that meeting and sends it.
- The engine's state is `meeting-sync-state.json` next to
  `history-sync-state.json`. The iPhone fetches on every return to the
  foreground. Debug Mac builds have no container entitlement and stay local.

## Export

Export asks for Notes, Transcript, or Notes and transcript, then writes one
Markdown file to `~/Downloads/<title>.md` (`<title> notes.md`,
`<title> transcript.md`; a number is added when the name is taken).
`MeetingStore.markdown(id:parts:)` builds it: notes first, transcript below.
The window shows the saved path with Show in Finder. Nothing is written into
the meeting folder. The menu's Copy section puts the same Markdown for Notes,
Transcript, or Notes and transcript on the clipboard instead. iOS shares the
same Markdown with both parts.

## ffmpeg

The app does not use ffmpeg; audio is read and written with AVFoundation.
ffmpeg is a development tool only (for playing test recordings) and is not
bundled.
