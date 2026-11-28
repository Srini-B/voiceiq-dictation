# Meetings on the Mac

How VoiceiQ notices a call, what audio it records, how each line goes to the
right person (AssemblyAI's speaker labels, on-device speaker separation, and
names from the call screen), and how the Meetings window shows
and exports it. Meetings are transcribed by AssemblyAI's pre-recorded STT-3.7
(Universal-2 for languages it lacks), always from the saved tracks
after the recording stops; there is no live transcript while a meeting
records. Notes and meeting chat come from the writing model (`gpt-6-luna`)
on AssemblyAI's LLM Gateway, which needs a balance on the account. Notes ask
GPT-6 models for reasoning effort medium (dictation and chat ask for none),
so the notes name far-side voices the same way from run to run and assign
owners correctly; they take about 40 s, in the background, and allow up to
32,000 output tokens, reasoning included. A reply cut off at that limit
fails the notes, with its own message, instead of being asked again. Each
notes request has 15 minutes, rate-limit waits included. There is
no on-device meeting transcription; a meeting that cannot reach AssemblyAI waits
with its audio and is sent when AssemblyAI can be reached ([ON_DEVICE.md](ON_DEVICE.md#meetings)). What is sent,
and the notes prompt, are covered in
[PRIVACY.md](PRIVACY.md) and [design/meeting-prompt-rulebook.md](design/meeting-prompt-rulebook.md).

## The transcription request

`AssemblyAIClient.transcribeSpeakers` uploads FLAC audio and starts a
transcript with `speaker_labels` where the request should tell voices
apart; the words come back with their times and speaker labels.
`MeetingTranscriber` sends only the stretches with speech, cut into windows
of an hour of speech each (AssemblyAI takes files of up to 10 hours and
tells voices apart better with more of each). Every window
after the first starts with reference clips of the speakers already found, so
a speaker keeps one id across a long call (`SpeakerLinker`). Finished windows
are cached beside the audio, so a retry never pays for the same audio twice.

What a request holds depends on the mic:

- **Echo-free mic on a call** (`CallAudio.micIsEchoFree`, the usual case with
  headphones or after `EchoCanceller`): each track is sent on its own
  (`MeetingTranscriber.transcribeTracks`). Every word from the mic is the
  note owner's; the far side's requests hold only the system track, so AssemblyAI
  tells apart only the other people. Double-talk survives because each voice
  is on its own track. Cached as `mic-N.json` and `far-N.json`.
- **Otherwise** (speakerphone echo the canceller could not remove, or a
  recording with no far side): both tracks as one levelled timeline
  (`CallAudio.samples`), as before. Cached as `N.json`.

Measured 2026-11-26 on AMI ES2004a as a call (one headset as the mic, the
other three summed as the far side), with Gemini as the provider: the mixed
request lost one of the four people and put 73.5% of words under the right person; the far side alone
found all three remote voices at 83.8%. The 2026-09-27 finding that a
far-side-only request returns a fraction of the speech held for the models of
that time, not `gemini-3.5-transcribe`.

## Who said what on the far side

On every call, the on-device speaker model (pyannote community-1, 21.6 MB,
in Settings as Speaker Separation) runs over the whole system track and
decides which far-side person said each word (`MeetingTranscriber.splitFarSide`,
cached as `transcribe-far-speakers-v1.json`). AssemblyAI's own far-side labels are
kept only when the model is unavailable or heard nobody. In an outside test
Gemini, the provider before 0.7.19, got the speaker count right in 16 of 36
runs; the model got 31 of 33 in ours
([activities/2026-11-06-offline-speaker-diarizer.md](../activities/2026-11-06-offline-speaker-diarizer.md)).
When the model is missing, the first meeting that needs it downloads it
without asking (`MeetingEngine.farSideDiarizer`); nothing it hears leaves the
Mac. The decision is in
[activities/2026-11-26-meeting-speakers-hybrid.md](../activities/2026-11-26-meeting-speakers-hybrid.md).

A far-side voice the model hears for less than 1% of the meeting is not a
participant: each of its words goes to the nearest word of another far-side
voice (`MeetingTranscriber.foldingStrayVoices`). On AMI ES2004a it was 8.7 s
of overlapping "yeah" and "okay".

A speaker's turn that runs past 20 s ends at its next sentence end, so a long
answer reads as paragraphs (`MeetingTranscriber.paragraphSeconds`). The
transcript views show them under one heading with the turn's first time.

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
3. a browser (`CallApps.browsers`, which includes Dia, Comet, Orion, Aside,
   Safari Technology Preview and Edge Beta, Dev and Canary, or any app named
   Chrome or Chromium) captures the mic on a page in `CallApps.meetingPages`,
   or plays sound on one of its call rooms (`CallApps.callRoomPages`: Meet,
   Zoom, Whereby, Jitsi, Slack huddles, vdo.ninja and others, not chat sites
   such as WhatsApp Web that play voice messages). Playing alone counts since
   2026-11-28: the live-call probe's owner joined vdo.ninja holding no mic, as
   a muted owner can, and got no offer. Pages are matched
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
and ends again. "Keep recording" keeps its full width beside "Stop now".
A recording started without a detected call is never stopped automatically. The rules
follow FluidVoice's; a browser call ends only when the browser plays no
other sound. While the screen is locked, a browser call counts only while
the browser captures the mic (`CallProcesses.isLive`): a browser can keep
its output open after the call hangs up as the Mac locks, and the recording
would otherwise run on. A call app keeps its output counting, since some
let go of the mic on mute. Hex does the same (`092a9b33`).
Option-M or Record pressed while a call is detected records that call, so
it stops the same way.

**Calendar (Mac and iPhone).** With **Use calendar for meeting notes** on
(off by default; turning it on asks for calendar access), a recording takes
the calendar event it falls in: an event that started before it or starts
within 10 minutes, not all-day, cancelled, free or declined, with other
people invited or a Zoom, Meet, Teams, Webex or Slack link
(`CalendarMeetings.event(at:source:)`). When several events fit, it takes
the one whose call link names the detected call's service, else the only
one under way, else the only one about to start; events that nothing tells
apart give none, so a wrong title and invitee list never reach the notes or
the speaker names. Its title shows in the list until the notes
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
invite's slack.com link is rarely the call. On the Mac the card's button and
the menu item (`NextMeetingButton`) read:

- **Join Zoom and Record**: starts a recording, then opens the link, so the
  call is recorded from its first second. The recording has no call source,
  so it records all system audio and is not stopped when the call ends. The
  button reads the same when call detection hears a Zoom call: detection
  knows the service, not the meeting, so that call may be another one.
  Speaker names are read from the linked app's window once it opens (Zoom,
  Teams, Webex), or from a browser tab showing a meeting page (Google Meet),
  never from another call app left open.
- **In Progress**, disabled, while any recording runs.

The recording takes the joined event's title and invitees
(`Upcoming.event`), not whatever event the clock falls in, so a meeting
joined early is still named right. A recording started from the menu shows
the pill, with its Stop, even when Accessibility is not granted. On iPhone
the button is **Join Zoom** alone, since the phone cannot record calls.
The screens refresh every 30 seconds, whenever the calendar changes and when
the calendar setting changes (`NextMeetingModel`); the menu reads the calendar each time it opens
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
- `inputDevice`: the first device with input channels that the first of
  those processes with running input captures. A process can list
  output-only devices (the built-in speakers) there, and the mic track never
  follows one (`CallDetector.firstInput`, from Hex `657aa0cf`).

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

**Output changes and silent taps.** A tap hears the output that was the
default when it was made. When the default output changes mid-meeting
(headphones in or out), or `system.caf` carried sound and then gets 15 s of
exact zeros while the tapped processes (all audio: the default output) still
play, `SystemAudioTap` starts a new tap on the same processes before it stops
the old one, and writes into the same file. The time between the old tap's
last buffer and the new one's first is written as silence
(`SystemTapWatch.gapFrames`, gaps under 50 ms are ignored), so `system.caf`
stays aligned with `mic.caf`. A new tap that fails to start leaves the old one
running and is tried again up to five times. A rebuild restarts the
count without waiting for sound, so a replacement that also delivers only
zeros is rebuilt again, after 60 s and then every 240 s until the track
carries sound, so a call that is really quiet while its app plays digital
silence is not rebuilt over and over. A retry from an older rebuild gives up
once a newer one has started. The mic track (`MicTap`) writes the time a
device move took as silence too, so it stays aligned with the system track
after an AirPods switch. Before 2026-11-26, switching headphones mid-call could leave the
rest of `system.caf` silent. From Hex (`5704885d`, `4a3e9d49`); not yet
measured on a live call.

**Mute my mic.** While a meeting records, the Meetings window shows **Mute
my mic** under Stop recording. Muted, `mic.caf` records silence of the same
length, so the timeline stays aligned, and the far side keeps recording;
the pill reads "Mic muted". **Unmute my mic** records your voice again.
Every recording starts unmuted. Hex has the same switch (`6118eb82`).

**Discard.** A recording you don't want can be thrown away instead of
stopped. The pill has a quiet × beside Stop; it asks "Discard this
recording?" with Keep and Discard in the pill itself, and moving the pointer
off the pill answers Keep. The Meetings window has a trash button beside
Mute my mic, which asks the same in a dialog. Discard
(`MeetingEngine.discardRecording`) stops both tracks, skips transcription
and notes, and deletes the meeting's folder through `MeetingStore.delete`,
not to the Trash; the pill shows "Recording discarded". Nothing was sent to
iCloud while it recorded (only finished meetings go up), and the delete is
sent like any other. If the folder can't be deleted, the meeting stays in
the list as failed with its audio, so it can be deleted by hand. Nothing
discards without that confirmation. From Hex (`01e5209b`).

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

The owner is everything on the mic when the tracks go separately, and otherwise the speaker heard from the mic and not from the far side
(`MeetingTranscriber.markOwner`). This runs only when the recording is a call
(`CallAudio.isOnline`): at least 5 s of far-side speech when the recording
started on a detected call (`MeetingMeta.source`), and 20 s otherwise.
Before 2026-10-27 every recording needed 20 s. A 2.5-minute Meet call had
15.9 s, so the owner became an ordinary speaker and got a participant's name
from the screen.

## How many people the call had

`ScreenSpeakerNames.expectedRemote` counts the other people the call showed:
the participants button read off the window
(`ScreenSpeakerNames.participantCount`, a count seen in at least two
snapshots, less one). It is used three ways:

- `MeetingTranscriber.place` maps a lone new far-side label onto the only
  known remote speaker only when the reference clip got no label of its own
  and the call showed at most one other person. With two or more, a new
  voice becomes a new speaker.
- `ScreenNames.remote` keeps the count and `ScreenNames.probablyMerged` marks
  a transcript with fewer far-side ids than that. The log says "speakers
  probably merged", and the notes request tells the notes model one label may
  hold several people. Silent listeners count too, so this is a likelihood.

`ScreenSpeakerNames.match` also gives the one far-side speaker the one other
name on screen when the call had at most one other person, though that name
was always visible.

Once the notes are written, `ScreenSpeakerNames.byElimination` names the last
far-side speaker still unnamed with the last calendar invitee not matched to
a voice, when the invite lists as many other people as the far side has
voices and that speaker said at least 10 words. Wispr Flow names the last
voice the same way. Single-word names count when they stay on screen in at
least a quarter of the snapshots and are no UI word
(`ScreenSpeakerNames.singleNames`, `uiWords`).

## Words follow their track

When the two tracks went as one timeline, `MeetingTranscriber.byTrack` runs
after the owner is marked: a
word heard only on the system track is not the owner's (when the mic is
echo-free, so mic silence means the owner was silent) and goes to the nearest
far-side speaker within 30 s, else to one new far-side id; a word heard
only on the mic is the owner's. MEASURED
2026-11-23 on a 22-minute three-person Meet call: 114 s of far-side speech had
come back as the owner's and 49 s of mic speech as a far-side speaker's. 

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
   windows through the Accessibility API at each sample (in a browser, only
   the window whose front tab is a call page, by its title or document): static text, image
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
then the screen match, then the notes model's
suggestion, then "Speaker N".
`MeetingMeta.knownNames` lists every name from those sources for Assign speakers.

Limits: a gallery view with every tile always visible gives no signal (a name
that is always on screen has no lift); banners covering a tag lose it; the
owner is named only when the call app marks their tile or row.

In a gallery view the names come from the notes request instead. Its
`speakers` answer names a voice that introduces itself, that others address
by one name in two or more turns, or that answers in the very next turn after
someone addresses a calendar invitee or on-screen name ("Sarah, you first.").
Then `ScreenSpeakerNames.byElimination` gives the last unnamed voice the last
unmatched invitee.

## The notes request

`MeetingNotesPrompt.build` writes the request; its rules and sources are in
docs/design/meeting-prompt-rulebook.md.

Rules added 2026-11-26 after a Fable judge scored the notes
([activities/2026-11-26-meeting-notes-quality.md](../activities/2026-11-26-meeting-notes-quality.md)):

- Every task with an owner goes in `actions`, one entry per task, even when a
  section covers its topic. A decision someone will make later is their
  action; a next step the whole group agreed to is an action with no owner.
- The speaker who says "I'll" owns the task, by name, never by role. A task
  keeps only its own spoken deadline.
- `notes` keeps every problem or concern someone raised and nothing nobody
  said. A call of a few minutes gets a short summary and only the sections
  that add something.
- When the notes come back with no action items but the transcript has a
  line with "I'll", "I will", "I can" or "I'm going to", the request is sent
  once more with those lines quoted (`MeetingNotesPrompt.missingActions`).
- When `byElimination` names a far-side voice the notes left unnamed, the
  notes are written once more with that name (`MeetingEngine.writeNotes`), so
  the voice's tasks carry it.

Fixes from 2026-10-29:

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
- **Dictionary spellings in the transcript.** The meeting request carries no
  Dictionary keyterms, so the transcript is heard verbatim.
  The Dictionary's wrong → right spellings (`ReplacementEngine`) are then
  applied to every segment before it is saved
  (`MeetingEngine.corrected`), as they are to a dictation, so the saved
  transcript, the notes and the chat all read the corrected words. Speakers
  and timestamps are unchanged.
- **No delete while busy.** A meeting that is recording, transcribing or
  writing notes can't be deleted, on the Mac (the More menu is disabled)
  or on iPhone (no swipe to delete), so its AssemblyAI calls never run on with
  nowhere to save.

## Renaming a meeting

A meeting's title comes from its notes (the notes model writes one), else
the calendar event, else its start time. **Rename…** in the Mac's `…` menu,
or in the long-press menu of a note's row on iPhone, sets the user's own
title (`MeetingStore.renameMeeting(id:title:)`, kept in
`MeetingMeta.userTitle`). It wins over the notes' title everywhere
(`MeetingMeta.shownTitle(notes:)`): the list, the detail, Export, and
agent access (`list_meetings` and `get_meeting`, whose search matches it
too). Redo notes writes its new title into `MeetingMeta.title` and leaves
`userTitle` alone. Renaming to an empty title puts the notes' title back.
Rename is unavailable while the meeting is recording or being written up,
like the rest of the menu. The title goes to iCloud with the meeting, like
a renamed speaker.

## Copy prompt for an AI agent

With coding-agent access on (Settings › Advanced › Coding agents,
[AGENT_ACCESS.md](AGENT_ACCESS.md)), the Mac's Export menu has **Copy prompt
for an AI agent**. It copies a short prompt (`AgentAPI.meetingPrompt`) that
names the meeting, tells the agent to read it with `get_meeting` and the
meeting's id (its UUID, as `list_meetings` gives it), and to search with
`list_meetings` and a query. The prompt says to turn access on if the agent
has no VoiceiQ tools. With access off, the item is not shown.

## Other side not heard

When macOS does not allow VoiceiQ to record system audio, the tap still
writes `system.caf`, but every sample is zero. On the Mac, a meeting that
call detection started (it has a `source`), that lasted over a minute and
whose `system.caf` is all zeros shows a warning under its title: "VoiceiQ
couldn't hear the other people on this call. Check System Settings > Privacy
& Security > Screen & System Audio Recording." with **Open System Settings**
(`Privacy_ScreenCapture`). `SilentSystemAudio.check` reads the track off
the main thread and stops at the first sample that is not zero, so only a
silent track is read to its end. A recording started by hand is not checked,
because a tap of all system audio is silent too when nothing plays; nor is
a meeting with no audio on this Mac (synced or imported). No permission is
queried.

## Editing the transcript

A finished meeting's transcript can be corrected one line at a time; a
turn under one speaker heading can hold several lines, each edited on its
own. On the Mac, right-click a line in the transcript column:
**Edit** opens a field above the transcript with the line's words (Return
or Save keeps them, Escape or Cancel leaves them), and **Delete…** asks
first, as deleting a meeting does. On iPhone, touch and hold a line in the
note's Transcript card, which also shows one heading per turn: **Edit** opens a sheet with the words, and
**Delete** removes the line at once, as a swipe deletes a note. Neither is
offered while the meeting is recording, transcribing or writing notes,
since a redo then would write over the change.

- The speaker and times of the line stay as they were, and every other
  line is untouched. `MeetingStore.editTranscriptSegment(_:text:meeting:)`
  and `deleteTranscriptSegment(_:meeting:)` name the line by
  `TranscriptSegment.id`, which stays the same when other lines are edited
  or deleted and when the line's own words change. Until a line is edited
  its id is a hash of its content, so no id is written for it and
  transcripts saved before editing existed are unchanged on disk and in
  sync. An edited line, or an exact repeat of an earlier line (a second
  "Yeah." with no times), keeps its id in `transcript.json` (`savedID`).
- The notes are not written again. **Redo notes** (Mac: the `…` menu;
  iPhone: Redo → Notes) writes them from the edited transcript.
- Everything that reads the transcript reads the edited words: the
  transcript views and their search, Export, questions about the meeting,
  Redo notes, and agent access (`AgentLibrary`'s meeting and search).
- An edit is a meeting change like a renamed speaker: it goes up to iCloud
  and the other device takes it
  ([Sync through iCloud](#sync-through-icloud)). **Redo transcript and
  notes** hears the meeting again and replaces the edited transcript.

## Redo and progress

- **Redo notes** writes the notes again from the saved transcript.
- **Redo transcript and notes** (`MeetingEngine.retry(id:fresh: true)`) drops
  the cached words (`transcribe-*`, and `local-words-*` and `speakers-*` from
  builds before 2026-11-10) and hears
  the whole meeting again. **Retry** after a
  failure keeps the finished windows.
- Redo and Retry transcribe from the saved tracks with AssemblyAI STT-3.7.
  A Retry after a notes-only failure rewrites only the notes (`MeetingMeta.failedStep`). `mic.caf` and
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
| `MeetingsView.swift` | Record button (with Mute my mic and Discard under it while recording) and folder menu above the list, the list in one section per day (Today, Yesterday, then the date) with each row's start time and length, each row's folders, the detail header (the folder menu ([Folders](#folders)), or the title while the transcript fills the pane, since the notes open with it; progress while transcribing or making notes, Update notes after a speaker is renamed, Play and Download audio (`RecordingAudioButtons.swift`), Export menu with Copy prompt for an AI agent, `…` menu with Rename / Redo notes / Redo transcript and notes / Retry / Delete, transcript toggle), the warning on a call whose other side was not heard, the export message |
| `MeetingNotesColumn.swift` | Title, then the day, start time and length (`MeetingMeta.whenText`; the iPhone shows the same line), and everyone heard (the note owner first, each with a dot in their transcript colour), Summary, the meeting type's sections, Decisions, Action items as open circles ("Owner: task"), Notes, then the meeting's questions and answers (`MeetingChatView.swift`, which also has the question box `MeetingsView.swift` puts under both columns) |
| `MeetingTranscriptColumn.swift` | The transcript in one `NSTextView`: one heading per turn (`MeetingSpeaker.turns`: lines in a row by the same speaker) with the name in its own colour (`SpeakerPalette`) and the turn's start time beside it, search that filters and highlights, Edit and Delete… on each line's right-click menu and the edit field above the transcript ([Editing the transcript](#editing-the-transcript)) |
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
goes to the writing model on AssemblyAI's LLM Gateway (`gpt-6-luna` unless
Settings → Advanced → Writing model names another).
`MeetingChat` builds the request:

- **System prompt.** Short answering rules, then the meeting as
  `MeetingStore.markdown(id:parts: .both)` builds it for Export: notes above
  the transcript, with speaker names and times. It is rebuilt for each
  question, so renamed speakers and redone notes are used from the next one.
- **Turns.** Every earlier question and answer, in order, then the new
  question. The model sees its own earlier answers, so follow-ups work.

It is sent with `AssemblyAIClient.chat` (`v1/chat/completions`). A model
with prompt caching reuses the repeated prefix; nothing extra is sent.

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
  it changes: renamed speakers, redone notes, an edited or deleted
  transcript line, a new question.
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

## Save each meeting as Markdown

Mac only, off by default. In Settings › Dictation, the meetings rows, turn on
**Save each meeting as Markdown** and choose a folder (**Choose…** changes
it; turning the switch off stops saving and leaves the files). Each
meeting is then written there as `<title> <yyyy-MM-dd>.md`, with the same
Markdown Export writes for Notes and transcript (notes above the transcript).
A name already taken gets ` 2`, ` 3`, and so on.

- **When.** `MeetingMarkdownFiles.follow` watches `gtMeetingsDidChange`,
  which `MeetingStore` posts after every save. A meeting is written once it
  is done and has notes: when its notes are first saved, and again after
  Redo notes, Redo transcript and notes, Rename…, a renamed speaker, a
  transcript edit, or a change synced from the iPhone. Meetings finished
  before the switch was turned on are written on their next change only.
  Nothing in the recording or transcription path calls it.
- **Your edits win.** `meeting-markdown-files.json` in Application Support
  keeps, per meeting, the file VoiceiQ wrote and the SHA-256 of what it
  wrote. A later change rewrites the file only while it still has that
  hash; a rename moves the file to the new name under the same rule (a
  change of letter case only, too). The name and the text come from one
  reading of the meeting. A file that appears at a new name just before the
  write is kept, and the next number is used. If the ledger cannot be read,
  nothing is written until it can (it is never treated as empty, which would
  give every meeting a second copy). The ledger is written before the file. If you edited, moved or deleted the file, it is left alone and the
  log says so (`meeting Markdown not rewritten`). Choosing a new folder starts
  fresh files there.
- **Never in the way.** Writing runs on its own background queue after the
  meeting is saved. A folder that is gone or not writable logs
  `meeting Markdown could not be saved` and changes nothing else. The log
  names the meeting by its id, never its title or the folder, and the
  folder setting is logged by length only.
- The app is not sandboxed (see `App/VoiceIQ.entitlements`), so the folder
  is kept as a path, without a security-scoped bookmark.

The rule of rewriting only a file that still matches what the app last wrote
comes from [Hex](https://github.com/anomalyco/hex) (MIT), `ee9b069a`
(`src/meeting/notes_file.rs`, `src/meeting/write/markdown.rs`).

## ffmpeg

The app does not use ffmpeg; audio is read and written with AVFoundation.
ffmpeg is a development tool only (for playing test recordings) and is not
bundled.
