# Meetings on the Mac

How VoiceiQ notices a call, how a recorded meeting gets speaker names from
the call screen, and how the Meetings window shows and exports it. Recording, transcription and the notes
prompt are covered in [LOCAL_TRANSCRIPTION.md](LOCAL_TRANSCRIPTION.md#on-device-meetings),
[PRIVACY.md](PRIVACY.md) and [design/meeting-prompt-rulebook.md](design/meeting-prompt-rulebook.md).

## Call detection

`CallDetector` polls every 5 s (two hits to offer, three misses to drop the
offer) and reads which processes have running input and output from Core
Audio's process objects (`kAudioHardwarePropertyProcessObjectList`, macOS
14.2+). A helper process is mapped to its app with
`responsibility_get_pid_responsible_for_pid`. It offers to record when:

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
   `CallApps.notCalls` and `notCallPages` leave out voice assistants,
   recorders and music software.

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

## The note owner

The owner is the speaker heard from the mic and not from the far side
(`MeetingTranscriber.markOwner`). This runs only when the recording is a call
(`CallAudio.isOnline`): at least 5 s of far-side speech when the recording
started on a detected call (`MeetingMeta.source`), and 20 s otherwise.
Before 2026-10-27 every recording needed 20 s. A 2.5-minute Meet call had
15.9 s, so the owner became an ordinary speaker and got a participant's name
from the screen.

## Speaker names from the screen

Call apps show the active speaker's name tag on their tile. VoiceiQ reads those
tags while it records and matches them to the diarized speakers afterwards.

Setting: **Read names from the screen** in Settings → Dictation
(`SettingsStore.meetingScreenNamesEnabled`, key `meetingScreenNames`, default
on). It needs Screen Recording, which the dictation onboarding asks for; a
meeting never raises the prompt (`CGPreflightScreenCaptureAccess`).

1. `MeetingEngine.startRecording` starts a `ScreenNameSampler` with the
   detected call source.
2. Every 3 s the sampler captures one image with ScreenCaptureKit:
   - the call app's or browser's largest on-screen window, when a source was
     detected (`SCContentFilter(desktopIndependentWindow:)`, so it works when
     the window is covered);
   - otherwise the main display, without VoiceiQ's own windows.
   The long side is capped at 2560 px.
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
   rows such as "Name (me)". A recording started by hand with no call
   detected reads the frontmost known call app (`ScreenNameSampler.frontCallApp`).
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
then the screen match, then the notes model's suggestion, then "Speaker N".
`MeetingMeta.knownNames` lists every name from those sources for Assign speakers.

Limits: a gallery view with every tile always visible gives no signal (a name
that is always on screen has no lift); banners covering a tag lose it; the
owner is named only when the call app marks their tile or row. The notes
prompt keeps the label "You" for the owner and adds their name as context.

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
| `MeetingsView.swift` | Record button above the list, the detail header (title, Update notes after a speaker is renamed, Export menu, `…` menu with Redo notes / Redo transcript and notes / Retry / Delete, transcript toggle), the export message |
| `MeetingNotesColumn.swift` | Title, Summary, the meeting type's sections, Decisions, Action items as open circles ("Owner: task"), Notes |
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
