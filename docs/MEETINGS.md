# Meetings on the Mac

How VoiceiQ notices a call, what audio it records, how each line goes to the
right person (the provider's speaker labels, the VoiceiQ Meetings Chrome
extension, and names from the call screen), and how the Meetings window shows
and exports it. Meetings are transcribed by the provider (Gemini or
OpenAI), or by ElevenLabs Scribe v3 when it is the transcription provider,
always from the saved tracks after the recording stops. With ElevenLabs, the
Meetings window (and the iPhone recorder card) also shows a live transcript
from Scribe v3 Live while the meeting records; it is replaced by the saved
transcript when the meeting stops. Notes always come
from the provider. What is sent, and the notes prompt, are covered in
[PRIVACY.md](PRIVACY.md) and [design/meeting-prompt-rulebook.md](design/meeting-prompt-rulebook.md).

### Live transcript with ElevenLabs

`LiveMeetingSession` mixes the mic and system tracks (the mic alone on
iPhone) into one 16 kHz stream to Scribe v3 Live with:

- `commit_strategy=turn_prediction`: the server's voice activity detection
  ends a segment at a pause, or the model ends it earlier when it predicts the
  speaker finished. Batch Scribe v3 has no VAD option, so this is where VAD is
  used.
- `diarize=true`: speakers in real time. `speakers_merged` events rewrite
  earlier turns when two ids turn out to be one person.
- `no_verbatim`, the dictionary as `keyterms` (50 terms of up to 20
  characters) plus the whole dictionary as the keyterm library (up to 10,000
  terms, first audio chunk), and the spoken languages (several turn on
  `multilang_mode`).

The live transcript is for watching the call. Measured 2026-11-12 on two real
four-person meetings (AMI corpus, 180 s each, scored against its speaker
labels): Live gave the right speaker to 95.0% and 73.7% of its words, batch
to 93.6% and 67.6%, but Live wrote 8% and 17% fewer words. So the saved
transcript still comes from batch Scribe v3 after the meeting stops, where
only stretches with speech are sent (`CallAudio.activeRegions`), which also
keeps billed silence down. A live session that fails says so in the window;
the recording and the saved transcript are not affected.

"Hide card and ID numbers in meetings" (off by default) asks batch Scribe v3
to write card details, ID, account and health-card numbers and passwords as
`{CREDIT_CARD}` and the like (`entity_redaction`), in the saved transcript and
so in what the notes model sees. Names, places, dates and money stay.

## Call detection

`CallDetector` polls every 5 s (two hits to offer, three misses to drop the
offer) and reads which processes have running input and output from Core
Audio's process objects (`kAudioHardwarePropertyProcessObjectList`, macOS
14.2+). A helper process is mapped to its app with
`responsibility_get_pid_responsible_for_pid`. It offers to record when one
of these rules matches. Rules 1 to 3 win over rule 4, whatever order the apps
come in:

1. a system call daemon (`avconferenced`, `callservicesd`) captures the mic:
   FaceTime and iPhone calls relayed to the Mac, which have no app process on
   the mic. Shown as "FaceTime or phone";
2. an app in `CallApps.known` (Zoom, Teams, FaceTime, Phone, WhatsApp, Slack,
   Discord, Webex, Skype, Messages, Telegram, Signal, Viber, LINE, WeChat,
   Messenger, Chime, GoTo, RingCentral, Tencent Meeting, DingTalk, Around,
   Tuple, Element) captures the mic. Apps that also record voice notes
   (`CallApps.voiceNoteApps`: WhatsApp, Messages, Telegram, Signal, Viber,
   LINE, WeChat, Messenger) count only while they also play sound, so a voice
   note does not raise the offer;
3. a browser captures the mic on a page in `CallApps.meetingPages`, matched
   against window titles and the URL of each window's `AXWebArea` (searched 9
   levels deep, 300 elements at most, as FluidVoice does for Safari);
4. any other app, or a browser on any other page, both captures the mic and
   plays sound. Two-way audio is what a call looks like whatever the app is.
   `CallDetector` keeps the first such app as `lookalike` and returns it only
   when no app or page matches rules 2 and 3. `CallApps.notCalls` and
   `notCallPages` leave out voice assistants, recorders, music software, and
   dictation and meeting-note apps (Superwhisper, Wispr Flow
   `com.electron.wispr-flow`, MacWhisper, Granola).

On 2026-11-02 Superwhisper was recording during a call in Chrome. It sorted
first, matched rule 4, and became the meeting, so names were read from
Superwhisper's window. Since 2026-11-06 a known call app or a meeting page
wins over rule 4, and Superwhisper is in `notCalls`.

VoiceiQ's own processes never count. Neither does an app whose audio goes
only through devices its own developer's driver provides: that is a remote
desktop host or audio router moving sound, not a call. Jump Desktop Connect
records "Jump Desktop Audio" and plays the client's mic into "Jump Desktop
Microphone" for a whole remote session; both devices come from
`com.p5sys.jump.audio.driver*` and the app is `com.p5sys.jump.connect`. The
developer is the first two parts of the bundle ID (`CallApps.vendor`); a
device's driver is the HAL plug-in that lists it (`kAudioPlugInPropertyDeviceList`).
That walk takes about 0.6 s on a Mac with AirPlay's thousand plug-ins, so the
map is cached until the device list changes. A call app used during a remote
session still counts: its developer differs from the driver's.

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
  process), and, for FaceTime and Phone (`CallApps.daemonCallApps`), of the
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

Everything here runs after the provider's transcript is back, on its
speaker-labelled words, so it works the same for every transcription
provider: Gemini, OpenAI and ElevenLabs.

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
   `MeetingTranscriber`, for every provider. The owner's words stay `you`.
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
   uses overlap over whole turns, not the moment a turn starts.
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

Setting: **Read names from the screen** in Settings → Dictation
(`SettingsStore.meetingScreenNamesEnabled`, key `meetingScreenNames`, default
on). It needs Screen Recording, which the dictation onboarding asks for; a
meeting never raises the prompt (`CGPreflightScreenCaptureAccess`).

1. `MeetingEngine.startRecording` starts a `ScreenNameSampler` with the
   detected call source. A recording started by hand with no call detected
   reads the frontmost known call app (`ScreenNameSampler.frontCallApp`).
   With no call app, the sampler does not run.
2. Every 3 s the sampler captures one window of the call app or browser
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
  Dictionary (vocabulary and spellings) and custom writing rules, as dictation
  cleanup does. The model fills a leading `glossary` field first: one entry per
  person, product and term, with every transcript spelling that means it
  (`"Nitin": ["Nithin", "Lithin", "Nathan"]`). Every other field uses those
  spellings. `MeetingNotes` ignores the field when decoding.

## Redo and progress

- **Redo notes** writes the notes again from the saved transcript.
- **Redo transcript and notes** (`MeetingEngine.retry(id:fresh: true)`) drops
  the cached words (`transcribe-*`, and `local-words-*` and `speakers-*` from
  builds before 2026-11-10) and hears
  the whole meeting again. `browser-speakers.json` stays. **Retry** after a
  failure keeps the finished windows.
- Redo and Retry transcribe from the saved tracks with the providers in
  `SettingsStore.meetingProviders` at that moment: the provider selected now
  first. `mic.caf` and `system.caf` stay until the meeting is deleted; the
  audio retention setting applies to dictations only.
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
| `MeetingsView.swift` | Record button above the list, the detail header (title, progress while transcribing or making notes, Update notes after a speaker is renamed, Play and Download audio (`RecordingAudioButtons.swift`), Export menu, `…` menu with Redo notes / Redo transcript and notes / Retry / Delete, transcript toggle), the export message |
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

## Asking about a meeting

Once a meeting has a transcript, a question box sits along its bottom
(macOS: under both columns, so it stays while the transcript is open; in a
narrow window, sending switches back to the notes, where the answers are
listed after the Notes section. iOS: pinned to the bottom of the note, with
the answers after the notes). A question
goes to the selected provider's writing model on its own API
(`AgentEndpoint.writingModel`: Gemini's formatting model or OpenAI's writing
model), never to Agent mode's custom provider.
`MeetingChat` builds the request:

- **System prompt.** Short answering rules, then the meeting as
  `MeetingStore.markdown(id:parts: .both)` builds it for Export: notes above
  the transcript, with speaker names and times. It is rebuilt for each
  question, so renamed speakers and redone notes are used from the next one.
- **Turns.** Every earlier question and answer, in order, then the new
  question. The model sees its own earlier answers, so follow-ups work.

It is sent through `AgentTransport` with no tools, the same adapters Agent
mode uses: Gemini `generateContent` and OpenAI's Responses API. Caching
follows `AgentCachePolicy`:

- OpenAI: automatic prefix caching, with `prompt_cache_key`
  `voiceiq-meeting-chat-<meeting id>`, so every question about a meeting
  lands on the same cache, also after a relaunch. GPT-5.6 and later keep it
  for 30 minutes.
- Gemini: implicit caching of the repeated prefix. Nothing is sent. Gemini
  3.x caches only from 4,096 tokens, so a short meeting is not cached.

Each answered question is saved with its answer, time and model in
`chat.json` in the meeting's folder (`MeetingStore.loadChat` /
`save(chat:id:)`), and the chat is there when the meeting is opened again. A
question that fails is not saved; the chat shows the error with Try again.
`MeetingChatModel.shared` keeps one chat per meeting while the app runs, so
leaving a meeting while a question is out and coming back shows it still
waiting. Usage is booked as Meetings › Meeting chat against the meeting.
Deleting the meeting deletes its chat.

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
