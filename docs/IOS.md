# VoiceiQ for iOS

A full QWERTY keyboard with VoiceiQ dictation on one tap and a cursor control
panel. The keyboard never records or calls a model. It sends
commands to the VoiceiQ app, which records, transcribes with your own API key,
and hands the text back.
Like the Mac, it runs on AssemblyAI with your own AssemblyAI API key.

## Targets

| Target | Contents |
| --- | --- |
| `VoiceIQiOS` | App: onboarding, keys, settings, history, notes (meetings), background voice session |
| `VoiceIQKeyboard` | Keyboard extension (`RequestsOpenAccess`), links `VoiceIQBridge` only; Hex's typing keyboard (`iOS/Keyboard/Hex`) |
| `VoiceIQLiveActivity` | Dynamic Island and lock-screen Live Activity |

All three share one App Group. Bundle IDs, the App Group and profile names
are in `project.yml`. The app declares
`UIBackgroundModes: audio` and `NSSupportsLiveActivities`, and handles the
`voiceiq://` scheme. Minimum iOS is 18. Every iOS target builds in the Swift 6
language mode.

`VoiceIQCore` builds for iOS and macOS. Files that need AppKit, Accessibility,
event taps, ScreenCaptureKit or Core Audio HAL are wrapped in `#if os(macOS)`.
iOS gets small stand-ins where the shared coordinator expects a type:
`SessionCoordinator/PlatformStubs+iOS.swift` (no screen context, no secure
input) and `MeetingEngine/MeetingCapture+iOS.swift` (an `AVAudioEngine` mic
tap, an empty system-audio file, no call detection). `VoiceIQBridge` is a
second, extension-safe library in the same package.

## How a dictation works

```
Keyboard ──command + Darwin ping──▶ App Group ──▶ App (background audio)
   ▲                                                   │ DictationCoordinator
   └──────snapshot + Darwin ping ◀── App Group ◀───────┘ → AssemblyAI
```

`VoiceIQBridge` defines the protocol:

- `KeyboardCommand` (`start`, `stop`, `cancel`), written only by the keyboard.
  `start` and `stop` carry the field the keyboard is in (`FieldIdentity`).
- `SessionSnapshot` (`off`, `warm`, `starting`, `recording`, `processing`,
  plus the last `Delivery` and `Notice`, and the field a dictation in
  progress is for), written only by the app.
- `ActivityRequest` (`stopDictation`, `cancelDictation`, `copyResult`,
  `endSession`, `stopMeeting`), written only by the Live Activity buttons.
- `fieldVisits`, the input sessions the keyboard was last in, written only by
  the keyboard.
- A heartbeat the app writes every second while a session is up.

Every key has one writer, so nothing is locked. Darwin notifications
(`io.blue.voiceiq.bridge.command`, `…state`) carry no data. They only mean
"reread the App Group". Both sides also reread on their own lifecycle events,
because pings are dropped while a process is suspended.

### Starting, then recording

A dictation reads as recording only once audio flows. Starting the audio
engine is not that moment: on a Bluetooth route the first buffer can come
seconds later. Until `AudioCaptureEngine` delivers its first non-empty buffer
(`AudioCapturing.onFirstAudio`, `DictationCoordinator.audioFlowing`), the app
publishes `starting`: the keyboard's mic bar shows "Starting…" with a spinner
and the Live Activity shows "Starting…". Then it publishes `recording`, and the
recording strip, its timer and the Live Activity's "Listening" begin. Stop
during `starting` (the keyboard's mic bar, the Live Activity's Stop) cancels the
start quietly, since there is nothing to transcribe. Adapted from Hex
(`a2d940e3`, MIT). The Mac is unchanged.

### Mic tap

1. The keyboard resolves the host app ([Returning to the app](#returning-to-the-app)),
   writes a `start` command and pings.
2. If the heartbeat is fresh (under 3 s), the app is running. The keyboard waits
   up to 0.7 s for the app to acknowledge the command. The app starts recording
   from the background. No app switch. The app acknowledges only when it can
   start in place (`AppModel.canStartInPlace`): it is in the foreground, or the
   session holds the mic open, so it can record from the background,
   and no background start has failed since the app was last opened.
3. Otherwise, or without an acknowledgement, the keyboard opens
   `voiceiq://keyboard/start?cmd=<id>&host=<bundle id>`. The app starts the
   background session in the foreground (iOS refuses to activate audio from the
   background), starts the dictation, waits until the mic is live (0.6 s at
   most), and sends the user back to the host app. When it can't, it shows
   "Swipe right along the bottom edge to go back".
4. Stop sends `stop` with the field the keyboard is in. The app transcribes,
   writes a `Delivery`, and pings. The delivery stays pending until a keyboard
   types it. [Where the text lands](#where-the-text-lands) has the rules.
5. If the heartbeat stops while the snapshot says `recording` or `processing`,
   iOS suspended or ended the app mid-dictation. The keyboard keeps the
   spinner and shows "Open VoiceiQ to finish"
   (`KeyboardModel.needsAppToFinish`). A tap opens `BridgeURL.app`. A suspended
   app resumes the dictation. An ended app recovers the saved recording at
   launch and delivers the text to the field the dictation was for
   (`VoiceSession.orphan`, `AppModel.deliverRecovered`), when the app ended
   less than an hour ago. When a new dictation began before the recovery
   finished, the recovered text stays in History and does not replace the
   new result. The session log records each dictation's processing
   time and whether the app was in the foreground ("processed in 94.2s
   (background)"), and when the app was opened during processing.

The keyboard's decisions go to `SharedStore.keyboardLog`, shown under
"Keyboard" in Settings › Advanced › Session log. Every line of that log, the
app's and the keyboard's, starts with the date and time
(`SharedStore.logStamp`, "2026-10-22 06:52:04", device time zone).

### Where the text lands

A dictation records in the app, so it keeps recording while the keyboard is
dismissed, while another app is in front, and while the user scrolls. The
text then has to find its field again.

The destination of a result (`Delivery.destination`) is the field where Stop
was tapped in a keyboard. When the dictation was stopped from outside a
keyboard (the Live Activity, the Action button, a call), the destination is
the field where Dictate was tapped. A result with a destination stays pending
for one hour (`Delivery.pendingWindow`). The app never copies it to the
clipboard unasked: the clipboard may hold what the user went to fetch.

iOS gives a keyboard no identity for a text field.
`UITextDocumentProxy.documentIdentifier` names one input session: the same
field reports a new identifier after the keyboard was dismissed, after another
field had focus, and after the app was left and reopened. So the keyboard
describes a field (`FieldIdentity`) by three things: the host app, the
session identifier, and a fingerprint of the text around the cursor
(`Draft.fingerprint`, an FNV-1a hash, nil for an empty field). For the
writing model, Dictate and Stop also carry the text around the cursor in a
prose field (`KeyboardCommand.surroundingText`: up to 300 characters before
and 100 after, nothing from code, number or address fields); it stays in the
App Group's command list until a later command drops it (commands older than
30 s go when the next one is sent; at most 8 are kept).

`Delivery.route` decides what the keyboard on screen does with a pending
result. It checks these rules in order:

| The keyboard is in | It |
| --- | --- |
| the same input session as the destination | types the text |
| the same app, and the text around the cursor is the same as at the destination | types the text |
| the same app, both fields are empty, focus did not move here from another field with the keyboard up, the keyboard has been in no other field of that app since Stop, and the text is less than 10 minutes old | types the text |
| any other field | shows "Dictation ready. Paste last puts it here." in the shortcut row |

The second and third rules apply only in a field that takes ordinary text
(`KeyboardModel.fieldTakesProse`). A field for a username, an email address,
a URL, a password, a one-time code, a card number, a phone number or a postal
code, and any field with a keyboard type other than the default, receives a
result only under the first rule. Everywhere else such a field gets the
offer.

A keyboard that is in no field does nothing with a result. iOS can leave a
dismissed keyboard polling with its view still in a window, and its text
connection then reaches nothing. `deliverIfNeeded` returns while
`documentIdentifier` is nil and logs "result held: this keyboard is in no
field" once.

Paste last types the result in the field on screen and marks it handled.
A result is typed once: the keyboard that types it writes
`insertedDeliveryID` and pings the app (`io.blue.voiceiq.bridge.inserted`).
After one hour the keyboard no longer types or offers the result unasked.
Paste last and History still have it.

The third rule is a guess. Nothing tells two empty fields of one app apart,
so the first empty field of that app that a keyboard comes up in receives
the text, whichever field it is. Two checks narrow the guess:

- `Delivery.isFirstReturn` reads `SharedStore.fieldVisits` and counts the
  input sessions since the user stopped the dictation (`Delivery.stoppedAt`),
  not since the text was ready. A field that had the keyboard while the text
  was being written counts. Without a stop time (a call ended the dictation,
  or the launch recovery wrote it), sessions count from when the text was
  ready. The destination's own session does not count.
- A field that focus moved to while the keyboard stayed up is never the
  field the result left, so the keyboard does not make the guess there
  (`InputSession.movedHere`). It offers the text. During such a move the
  keyboard can read no field for one 0.1 s poll, so it counts less than one
  second in no field as a move (`KeyboardModel.moveGap`). A keyboard that
  appears again (`KeyboardModel.appeared`) starts fresh.

An input session in an app that the keyboard could not name counts as a
session in the destination's app, so an unknown session leads to an offer,
not to typed text. While it polls, the keyboard asks the host resolver for a
missing app name at most three times per session
(`KeyboardModel.hostRetryLimit`). A tap on Dictate or Stop always asks.

The second and third rules compare what the field looks like, so the
keyboard acts on them only when two polls in a row read the same field. A
reading taken while the host app is still connecting cannot place a result.
Only the keyboard instance on screen may type: iOS can keep an earlier
instance alive in the same process, still polling, with a text connection
that reaches no field. The keyboard inserts with
`textDocumentProxy.insertText` and adds a space when the text would run into
the previous word.

A new dictation replaces the pending result of the one before. The earlier
text stays in History. When the earlier result still waited for its field,
the keyboard shows "Previous dictation is in History" and the session log
records "a waiting result was replaced; it is in History".

The fingerprint in `Delivery.destination.draft` is needed only while the
result is pending. Once a keyboard typed the result, the app copied it, or
the hour passed, the app writes the result back without the fingerprint
(`Delivery.forgettingDraft`, `VoiceSession.resultSettled`). The app does the
same at launch.

A result with no destination (the Action button with no VoiceiQ keyboard on
screen) is typed by the first VoiceiQ keyboard on screen within two minutes.
When no keyboard typed it two seconds after delivery, the app puts it on the
clipboard and marks it handled.

Settings › Privacy has
the same "Keep dictations" picker as the Mac (`transcriptRetentionDays`);
`AppModel` runs `RetentionPolicy.purge()` on launch.

#### The transcript as a draft

**On in the prose fields of Messages, Reminders, Contacts and Calendar (`Delivery.draftHosts`, 2026-11-28; `activities/2026-11-28-iphone-draft-hosts.md`).** In every other app, including Safari and every other browser, the keyboard types the written text once, as before drafts. The first swap committed the draft, deleted it key by key and typed the written text. In Messages, after one dictation and typed text, the second dictation's swap left the field holding only the written text, while the keyboard's `documentContextBeforeInput` read exactly the text it expected (52 characters against the field's 27). The swap is now one insert over the marked draft, described below. It was tried in the Simulator, not on a device (`activities/2026-11-28-iphone-draft-swap-by-insert.md`).

What a keyboard can rely on, measured in the iOS 27.0 Simulator in Messages, its search field, the app's Try it field and a Safari textarea:

- The host gets the calls of one run loop turn as one batch and applies its insertions and deletions before its marked-text calls, whatever order they were called in. `unmarkText` then a key in one turn replaces the marked text with the key; `unmarkText` then Delete removes it; `unmarkText` then `setMarkedText` replaces it with the new marked text.
- `insertText` over marked text replaces exactly the marked text and leaves plain text.
- `unmarkText` works when no other call follows in its turn. A wait of 0 ms was enough.
- Delete on marked text removes all of it in the UIKit fields. The Safari textarea lost one character.
- The proxy's text is a copy the keyboard's process edits call by call. It leaves marked text out of `documentContextBeforeInput`, and after a batch the host applied differently it shows a field that isn't there. Messages sent fresh text after Send (`textDidChange`). A tap in the field while text was marked left it marked and sent the keyboard nothing.

When the keyboard never left the field (the first rule above) and the
writing model will rewrite the transcript, the keyboard shows the
transcript first and swaps in the written text about a second later. This
is the Mac's draft (`TextDraft`), done by the keyboard:

1. The moment the transcript is heard, the app publishes it as
   `SessionSnapshot.draft`, a `Delivery` with the same destination.
2. A keyboard on screen in the destination's input session types it with
   `setMarkedText`, fitted like any result. iOS hosts underline marked
   text. The keyboard then writes the draft's ID to
   `SharedStore.typedDraftID` (writer: keyboard). It types a draft only
   within 0.45 s of its creation (`Delivery.draftWindow`), never over a
   selection, and never into a field that reports text (`hasText`) but
   shows none around the cursor, since an edit there could not be noticed.
   Undo history is cleared when a draft goes in.
3. The app offers a draft only for a destination in `Delivery.draftHosts`,
   so the written text is never held back elsewhere. A destination whose app
   the keyboard could not name at Stop (at Dictate, for a dictation stopped
   outside a keyboard) gets no draft. It waits up to 0.6 s
   (`Delivery.draftWait`) for that ID, then
   withdraws the draft from the snapshot. Without the ID, the written text
   comes as a plain result that still names the draft, in the dictation's
   insert turn (`DraftShown.pending`): a keyboard whose report was late
   swaps its draft, and any other keyboard types it as before.
4. The written text comes as a delivery with `replacesDraft` set to the
   draft's ID. The keyboard inserts it with one `insertText`, the only
   call of that turn, which takes the place of the marked draft and of
   nothing else (`KeyboardDraft.replace`). It does so only while the field
   still looks as the draft left it (`KeyboardDraft.isInPlace`): the field
   has text, nothing is selected, and the text around the cursor is the
   text that was there, with or without the draft. Otherwise the draft
   stays as heard, and the session log says why. The keyboard never presses
   Delete on a draft and never reads the field to check a write.

   Where a host made the draft plain text without telling the keyboard,
   the insert lands beside it: the dictation is there twice, and no text is
   lost. So the keyboard types drafts only in apps this was tried in
   (`Delivery.draftHosts`: Messages, Reminders, Contacts, Calendar). Safari stays off: a page field whose script rewrites its value on every change makes the draft plain text without telling the keyboard, and every dictation went in twice, while a plain textarea and a contenteditable passed; a keyboard can't tell these fields apart. Notes, Mail and third-party apps (WhatsApp, Slack, Chrome, Gmail) can't run in the Simulator and wait for a device run. For that run, Settings › Advanced › Try drafts in Notes, Mail and WhatsApp (off by default; `SharedStore.triesMoreDraftHosts`, writer: app) adds `Delivery.trialDraftHosts` for both the app's offer and the keyboard (`Delivery.takesDrafts`). The session log names the app each draft was typed in. No transcript with a line break is drafted
   (`KeyboardDraft.canType`). Elsewhere the
   written text goes in once, as before.
5. A dictation whose transcript comes while an earlier one's draft is still
   marked (its writer still running, also while a later dictation records;
   started from the Action button or Control Center, or the earlier
   transcript came late) joins that draft (`KeyboardDraft.add`): the
   marked text becomes both transcripts, each fitted to the text before
   it, since new marked text replaces the old and a second, separate draft
   would take the first one's place. Each written text takes its own part's
   place in the marked text as it comes, in either order
   (`KeyboardDraft.Swap.waiting`; a written text with a line break is not
   marked, and the field keeps that part's transcript until then), and the
   whole goes in with one `insertText` once every part has its written
   text. A field that changed around the draft takes no new part, and that
   dictation's written text comes alone. Whether a draft still waits is not
   read from the phase, which shows only the foreground dictation: the app
   lists the drafts whose written text is still to come
   (`SessionSnapshot.writingDrafts`, from the moment a draft is confirmed
   or given up on, before the offer is withdrawn, until its job ends), and
   the keyboard makes a draft plain as heard once none of its unwritten
   parts is listed or offered and no written text for it waits. The
   snapshot holds one result, so the app holds a written text that names a
   draft until the keyboard has handled the one before it that names
   another draft (up to `Delivery.draftWait`). The keyboard remembers the
   last eight drafts it typed (`KeyboardModel.typedDraftIDs`, in its own
   `UserDefaults`), so a written text for a part of a draft that ended
   early is marked handled, never typed beside its transcript.
6. A written text whose draft this keyboard no longer holds (the keyboard
   was dismissed or moved to another field) is marked handled and never
   typed beside the draft.
7. A dictation that ends without written text (Cancel, no speech, a
   failure) leaves its draft in the field as heard: the keyboard does not
   take text back out of a field. The Mac does (`DraftStage.withdraw`).

While the keyboard holds a draft, the strip shows a writing animation (one
crest sweeping across five bars) instead of the spinner. The draft then
ends in one of three ways, each one kind of call (`KeyboardDraft`):

| What happens | The keyboard's call | The draft |
| --- | --- | --- |
| The written text comes | `insertText(written)` | replaced |
| A key, Delete, a cursor move, Paste last or Undo on this keyboard (`EditController.willEdit`) | `insertText(draft)`, then the edit in the same turn | plain text, as heard, with the edit after it |
| The keyboard is dismissed, the field changed without the keyboard (read every 0.1 s and on `textDidChange` and `selectionDidChange`), another dictation starts, or no written text comes | `unmarkText()`, and nothing else in that turn | plain text, as heard |

A new draft is marked only in a poll that began with none, or that began
with a held draft no call of that turn has changed (step 5), and the poll
that ends a draft with `unmarkText` types no result: either would reach
the host before the `unmarkText` and replace the draft. Paste last and
History always have the written text.

When another app is opened over a draft, iOS tells the keyboard seconds
later, and what the keyboard writes until then reaches no field: back in the
app, the field still shows the draft marked, no keyboard holds it, and the
next key would replace it. A keyboard cannot tell which of its writes were
lost. So it keeps the app and input session of the last draft it typed
(`KeyboardModel.lastDraftPlace`, in the keyboard's own `UserDefaults`, since
iOS often ends the keyboard's process while its app is away), and the first
poll of the next input session in that app sends one `unmarkText` and
nothing else (`settleLeftDraft`), then forgets the place. The draft is then
plain text, as heard. Where nothing is marked the call changes nothing. A
session in an app the keyboard cannot name gets one `unmarkText` too, since
it may be that app (a new keyboard process can name none), and the place is
kept until that app is named. This is the one call the keyboard makes for a
draft outside `Delivery.draftHosts`.

The keys plan an edit from the text before the cursor before they make it:
autocorrect counts its Deletes from the word it read, and a word-wise move
its offset. The proxy leaves a marked draft out of that text. So while a
draft is held, the keys read the proxy's text with the draft added
(`KeyboardDraft.textBefore`, through `TypingBridge.documentContextBeforeInput`),
and the keyboard's own cursor moves and Paste last make the draft plain
before they read. Shift reads the same text: the host tells a keyboard
only of changes made elsewhere, so after marking or changing a draft the
keyboard refreshes the keys itself (`KeyboardModel.onDraftChange`). Without
that, Shift stayed as it was before the draft, and after "Earlier line. "
the first letter typed during a draft that ends mid-sentence came out a
capital. Planned from the proxy's text alone, a space after a draft
would have corrected the word before the draft and deleted into both.

After any `unmarkText` the keyboard types no result and marks no draft for
0.05 s (`KeyboardModel.unmarkQuiet`): two polls can run in one turn of the
run loop. A key, Delete, cursor move, Paste last or Undo tapped in the turn
of a `setMarkedText` or `unmarkText` runs on the next turn instead
(`KeyboardModel.markedTextThisTurn`, `EditController.runsNow`): the host
would apply it first, so it would land before a new draft, which then went
in twice, or replace a draft just made plain. Paste last waits the same way, and a result waits for the next poll. The keys read the text before the cursor with
the edits still waiting in it (`EditController.projected`), so a word-wise
Delete reads each next word after the last one it took. That counts inserts
and Deletes before the cursor only, not a waiting cursor move or a Delete
over a selection. The deferral was checked against the fake host
(`HostField`); no Simulator tap landed in such a turn.

The keyboard does not show a spinner in the field before the draft
lands. It would be marked text too, and a host commits marked text as
plain text when focus moves or iOS ends the keyboard, which would leave a
spinner glyph in the user's text. The strip's spinner shows the wait
instead.

### Returning to the app

The keyboard learns the host's bundle ID from two private UIKit surfaces
(`HostAppResolver`, the approach Dictus uses): `_hostProcessIdentifier` on its
input view controller gives the host's pid, and
`_UIKeyboardArbiterClient.currentClientState` reports (bundle ID, pid) pairs.
The pairs go into a pid table that lives as long as the keyboard process. The
arbiter often still names the previous host when the keyboard appears, and
after a bounce it names VoiceiQ or nothing, so the table keeps every pair it
has seen: a host seen once in this keyboard process resolves from then on.
Pids are handed out in sequence, so a stale entry would need a pid wrap to
point at the wrong app. iOS offers no list of installed apps.

`HostReturn.returnToHost` tries, in order:

1. `AppLauncher.open(bundleID:)`: private `LSApplicationWorkspace
   openApplicationWithBundleID:`, the same as picking the app in the app
   switcher. It works for any app and resumes it where it was, including
   Safari. The app confirms it left the foreground a second later; if not,
   it falls through.
2. The app's return URL: a user override from Settings, or the
   `KnownAppSchemes` table. An `https` URL opens only as a universal link
   (`universalLinksOnly`), so it never lands in Safari.
3. The swipe-back screen.

System UI hosts (SpringBoard, Spotlight, SafariViewService, Shortcuts UI and
compose extensions) skip step 1. Each bounce is recorded per bundle ID and
shown in Settings › Return to Apps; the session log has a
`return to <bundle id>: launched | url opened | launch refused` line.

History and Home show the target app's name from its bundle ID
(`AppNames`): the built-in table first, then a name looked up once on the App
Store (`https://itunes.apple.com/lookup?bundleId=`, only the bundle ID is
sent; Apple apps are skipped) and cached, then a guess from the last
meaningful bundle ID segment (`com.acme.notes.ios` → "Notes", not "Ios").

### The background session

Dictation and meeting recording use the shared [sleep guard](POWER_MANAGEMENT.md).
It disables Auto-Lock while VoiceiQ is in front, and restores it when no
dictation, meeting recording, or meeting write-up (transcript and notes) remains. It cannot control Auto-Lock in the
keyboard's host app. A warm microphone alone does not hold the sleep lock.

iOS lets a backgrounded app start a *mixable* recording only while it is
already recording. The SDK header (`CoreAudioTypes/AudioSessionTypes.h`,
`AVAudioSessionErrorCodeCannotStartRecording`, `'!rec'`) states the rule:
"The app is not allowed to start recording, usually because it is starting a
mixable recording from the background". Measured on device (builds 13 to 15):
silent playback alone and a Live Activity both failed at the second in-place
start; only an open mic worked. Two alternatives were tried and removed: a
Picture in Picture keeper (held the session, but left a tab at the screen
edge) and a non-mixable "Background audio" session with the mic closed (did
not start in place on the owner's device; removed on 2026-10-21 along with
the Skip app switching picker).

`KeepAliveAudio` is the one keeper. It plays silence on a `.playAndRecord`
session (default to speaker, A2DP, mix with others; HFP only while a
dictation set to Bluetooth records) and taps `inputNode` without keeping the buffers,
so the mic stays open and the orange dot shows. `VoiceSession.isActive` says
whether it is up. It lasts `MobileSettings.warmWindow` after each dictation
(Settings › Dictation › "Keep mic on after dictating": Never, 5 s to 12 h,
default 30 s; key `warmWindowSeconds`), counted from when the text is
delivered; Home shows "Turns off in" with the countdown. With "Never" the
session ends once the text is delivered, so the next keyboard tap opens
VoiceiQ again. The audio session stays open until then: it is what keeps iOS
from suspending the app while a slow transcription runs, at the cost of the
mic dot showing until the text arrives.
`AudioCaptureEngine` never configures the session, so each dictation's capture engine records into it.

Settings › Dictation › Microphone (`MobileSettings.microphoneChoice`, key
`microphoneChoice`) picks what a dictation records from: Automatic (the
default) takes a wired headset's mic, then USB, then the car's in CarPlay,
then the iPhone's; iPhone always takes the iPhone's; Bluetooth takes the same
list with Bluetooth hands-free and LE mics before the iPhone's, and is the
only choice that adds `.allowBluetoothHFP`, so AirPods or a car switch to
call audio only while such a dictation records. Between dictations the warm
session always pins the iPhone's mic without HFP: `AppModel`'s capture
factory calls `VoiceSession.useDictationInput()` before each capture engine
starts, and the session returns to the iPhone's mic once transcription
starts (capture has stopped by then), and again at `.warm`. Meetings record from the warm session's input, the iPhone's
mic. The setting replaced the Bool `preferBuiltInMic`: a stored `true` reads
as Automatic and `false` as Bluetooth until the user picks again. The port
orders come from Hex (see `THIRD_PARTY_NOTICES.md`).

Voice isolation (Settings › Dictation, `SettingsStore.voiceIsolation`, off by
default) turns on voice processing in the dictation's `AudioCaptureEngine`,
which turns down background noise, with the same raw fallback as the Mac, and
records in the `.voiceChat` session mode; the warm session goes back to
`.default` with the iPhone's mic. The mode alone does not process the mic
(Apple applies voice processing only with Voice-Processing I/O). Voice chat enables hands-free Bluetooth by
itself, so with AirPods connected a dictation can switch them to call audio
whatever the Microphone choice. From Hex `492d8c28` (MIT).

A session that the keyboard started shows a Live Activity (Settings ›
Dictation › "Show in the Dynamic Island", `MobileSettings.showsSessionActivity`,
on by default; "Show on the Lock Screen" on iPad). It is how the user stops
or cancels a dictation while no VoiceiQ keyboard is on screen. While a
dictation starts or records, the activity has Cancel and Stop. While a result
waits for its field, the activity says "Text ready" and has Copy, which puts
the text on the clipboard and marks it handled. The activity is a control,
not a keeper: the open mic is what lets the app record in the background.
ActivityKit starts an activity only from the foreground, so
`VoiceSession.refreshActivity` starts a missing one the next time the app is
in front. The activity ends with the session, so "Text ready" shows only for
the warm window. The result stays pending without it.

The session also ends when the user taps End (app or Dynamic Island) or when
an audio interruption cannot be resumed. A call or Siri interruption
finalizes an in-progress dictation, so the words are kept. Settings ›
Dictation has an "Open Action Button settings" button
(`App-prefs:ACTION_BUTTON`, falling back to VoiceiQ's page in Settings).

Home shows "Skips app switching" while the session is up and "Needs app
switching" otherwise. The session log (Settings › Advanced) records session
starts and background mic starts.

### Action button

`DictationControl` (in the widget extension) is a Control Center control,
"VoiceiQ Dictate", which the user can assign to the Action button. Its
`ToggleDictationIntent` is an `AudioRecordingIntent` and a
`LiveActivityIntent`, so iOS runs it in the app's process (launching it in the
background if needed) and lets it open the mic without bringing VoiceiQ
forward. It calls `ActionButtonBridge.toggle`, which `AppModel` sets at launch:
stop the dictation in progress, or begin a session with a Live Activity (iOS
requires one for an audio-recording intent) and start a dictation for whatever
app is in front. The keyboard follows the shared snapshot like any other
dictation. When a VoiceiQ keyboard stops it, the text goes to that keyboard's
field. Otherwise the result has no destination, and
[Where the text lands](#where-the-text-lands) says what happens to it.

The control is a `ControlWidgetToggle`, on while a dictation starts or
records. Its value provider reads `SharedStore.isDictating()`, which is the
snapshot phase `starting` or `recording` with a live heartbeat.
`VoiceSession.publish` calls `ControlCenter.reloadControls(ofKind:)` each time
the phase enters or leaves those two, so the control stays lit for the whole
dictation and should turn
off when it stops from any path. A press, from Control Center or the Action
button, runs `SetDictationIntent`, a `SetValueIntent` with the same work as
`ToggleDictationIntent` (`ActionButtonBridge.run`). It ignores the value iOS
passes and toggles the real state: the app's reload does not always reach the
control (seen after a cancel on the keyboard), and a press on a control left
on must still start a dictation.
`ToggleDictationIntent` stays the App Shortcut, because a `SetValueIntent`
would make Siri and Spotlight ask for its value.

### iPad

The app and both extensions target iPhone and iPad (`TARGETED_DEVICE_FAMILY`
`1,2`). The iPhone stays portrait; the iPad supports every orientation, so it
runs full screen, in Split View and in Stage Manager windows.

Layout follows the horizontal size class, not the device:

- Regular width (an iPad window wide enough): History, Notes and Settings
  use `ListDetailNavigation`, a `NavigationSplitView` with the list on the
  left and the selected item on the right. Neither column shows a title or
  a bar background: the tab bar above names the page, and in Settings the
  open section's row is tinted in the sidebar (`List(selection:)` over
  `SettingsSection`). Pages pushed inside the detail column keep their
  title and back button. History's detail is keyed by the dictation id
  (`.id(record.id)`); without it the split view kept the first dictation's
  state when another row was picked. Home puts the session, setup and
  hardware keyboard cards in one column and Try it, stats and recent
  dictations in a second.
- Compact width (iPhone, narrow iPad windows): the iPhone layout, with a
  `NavigationStack` per tab.

On iPhone the bottom tab bar shrinks to the current tab's icon while a page
scrolls down (`tabBarMinimizeBehavior(.onScrollDown)`, iOS 26 and later).

Scrolling pages cap their content with `.readableWidth()` (720 pt; Home 1080,
onboarding 560). The tab bar is the system one, which iPadOS draws at the top.
Copy that names the device ("Use iPad microphone", "kept on your iPad") reads
`UIDevice.localizedModel`.

#### Hardware keyboards

With a keyboard case attached, iPadOS shows no on-screen keyboard, VoiceiQ's
included, and only Apple's own keyboards have hardware layouts. The case's
dictation key always starts Apple's dictation; apps cannot receive it or
change what it does. So on iPad the keyboard is not the way in.

The way in is `ToggleDictationIntent`, the same intent as the Action button
control. `VoiceIQShortcuts` (an `AppShortcutsProvider` in
`VoiceIQMobileApp.swift`) publishes it as "Dictate with VoiceiQ" with no
setup, so it runs from:

1. Control Center: the VoiceiQ Dictate control.
2. Spotlight: ⌘Space, "Dictate with VoiceiQ", Return.
3. Siri: "Dictate with VoiceiQ".
4. A key combination of the user's choice: put the action in a shortcut in
   the Shortcuts app, then assign that shortcut in Settings › Accessibility ›
   Keyboards › Full Keyboard Access › Commands. iPadOS has no other way to
   bind a global key to an app action; Full Keyboard Access also draws focus
   rings while it is on.

Run it once to start and again to stop. No keyboard types the result, so after
two seconds it goes on the clipboard (the existing `copyIfNotTyped` path) and
the user presses ⌘V. The session log records whether the clipboard write took
effect (`UIPasteboard.changeCount` before and after) and whether the app was
in the foreground or the background at that moment.

On an iPad, which has no Dynamic Island, iPadOS shows the Live Activity as a
banner for a few seconds when it starts and then hides it. It stays on the
Lock Screen only. An app cannot keep the banner on screen, so the Control
Center toggle is the in-session indicator and the way to stop. On iPad, Home, onboarding's Try it page and
Settings › Dictation show these steps in a "Hardware keyboard" card in place
of the Action button section.

### Setup status

`SetupMonitor` (app) publishes `SetupStatus`: microphone permission, whether
the keyboard is added, Full Access, and Live Activities. It rereads the App
Group with `SharedStore.reloadFromDisk()` whenever the app becomes active, when
the keyboard pings `io.blue.voiceiq.bridge.keyboard` (`SharedStore.noteKeyboardSeen`,
posted each time the keyboard appears), and on `activityEnablementUpdates`.
Returning from Settings with Full Access turned on shows it as granted without
restarting the app, once the keyboard has opened: iOS gives the app no way to
read the Full Access switch, so until the VoiceiQ keyboard has run with it,
the setup card shows "Open it once" and "Not confirmed", and the Try it card
lists how to switch to the VoiceiQ keyboard with the globe key.

Permissions can be taken back after onboarding (2026-09-30):

- Microphone switched off in Settings: iOS ends the app, and the next launch
  shows the Microphone line unchecked in Finish setup and "Set up" on
  Settings. A keyboard tap that opens the app (`startFromKeyboard`) no longer
  opens a session that cannot record and sends the user back to the host
  app: with no API key or no microphone it stays in VoiceiQ with a banner and,
  for the microphone, the Keyboard & Permissions sheet (Settings button when
  denied; when not yet asked it asks). Start meeting does the same. The
  Action button's intent throws `ActionButtonRefusal` with the reason
  ("Allow the microphone in VoiceiQ"), because nothing else is on screen to
  show it. A tap in the keyboard while a warm session runs still gets the
  keyboard notice, as before.
- Keyboard removed from Settings › Keyboards: `SetupStatus.current()` clears
  `keyboardSeenAt`, so a keyboard added back reads "Open it once" until it
  runs with Full Access again, instead of "Ready".
- Full Access switched off: the keyboard shows "Allow Full Access", which
  opens `voiceiq://keyboard/setup`. That link is sent only by a keyboard
  without Full Access, so the app clears `keyboardSeenAt` on it before showing
  the setup sheet. The keyboard cannot report this through the App Group,
  which needs Full Access.

Onboarding saves its page in `MobileSettings.onboardingStep`,
so a trip to Settings resumes on the same page.

Onboarding has four pages: welcome, the AssemblyAI API key, permissions
(microphone and keyboard together), and a Try it field.

### Design system

`iOS/App/Sources/Design/Theme.swift` holds colours, radii, spacing and type
(Google Sans Flex, bundled in `Resources/Fonts`, registered through
`UIAppFonts`). `Components.swift` holds the shared pieces: `PillButtonStyle`
(`.primaryPill`, `.secondaryPill`, compact variants), `Card`, `GroupLabel`,
`BrandMark`, `Wordmark`, `StatusChip`, `CheckLine`, and
`.keyboardDismissable()` (a Done button above the keyboard plus interactive
scroll dismissal). Every CTA uses a pill style. The launch screen shows the
app mark (`LaunchMark`, `LaunchBackground`). The brand image sets are
rendered from the app icon.

### Notes

The Mac's Meetings tab is called **Notes** on iPhone and iPad: the phone cannot
record calls, so the feature is a recorder for notes, not a call companion. The
code keeps the `Meeting*` names. Notes run in the app like a recorder: Record
notes, the phone records the
room with the mic, Stop, then `MeetingEngine` transcribes and writes notes. The
Live Activity shows the running time with a Stop button. iOS does not allow
recording other apps' or call audio, so `SystemAudioTap` writes an empty
`system.caf` and the pipeline treats every meeting as in-person: there is no
far-side reference, so `MeetingTranscriber.callAudio` skips echo cancellation
(the WebRTC AEC3 xcframework ships a macOS slice only and is not linked on
iOS). Speaker linking, meeting-type notes, suggested speaker names and Redo
(notes only, or transcript and notes) work as on the Mac. Dictation is refused
while notes record. Notes are transcribed by AssemblyAI after you stop, as on the
Mac; there is no live transcript while they record.
Folders work as on the Mac (MEETINGS.md, Folders): the folder button in the
list's toolbar shows one folder and makes, renames, or deletes folders; the
folder button on an open note, a long press on a row, or a swipe right on a
row (Folders, which opens a sheet) files it.
A long press on a note's row also offers Rename… (a title of your own that
Redo notes keeps; MEETINGS.md, Renaming a meeting). A long press on a line
of a note's transcript offers Edit (a sheet with the line's words) and
Delete (MEETINGS.md, Editing the transcript).

### Keyboard

A full English QWERTY keyboard with VoiceiQ's shortcut row on top. The typing
keyboard is Hex's (`anomalyco/hex`, MIT), vendored under `iOS/Keyboard/Hex`;
the shortcut row, the recording strip, the edit panel and the dictation
hand-off are VoiceiQ's. The keyboard never records: Dictate hands off to the
app as before.

**Layout** (`KeyboardView`). The keyboard is exactly as tall as Hex's own:
VoiceiQ adds no row.

- The suggestion row holds VoiceiQ's shortcuts at its ends: cursor control
  and Paste last dictation on the left (on the cursor page only its own key
  has it), Dictate (a waveform in front of VoiceiQ's mark, on the blue pill)
  on the right; without Full Access Dictate opens the app's setup. All
  are 44 pt wide with 6 pt gaps (`TypingBridge.buttonWidth`), and the row is
  laid out between the keys' outer edges, so the buttons line up with the
  keys in every orientation (`stripRow`, from Hex's `onStripRowLayout`). Hex's
  suggestions sit between them (`KeyboardLayout.reservedStripEnds`,
  `0003-voiceiq-strip-row.patch`). A long suggestion shrinks from 15 pt down to
  10 pt to fit whole (`0008-voiceiq-strip-fit.patch`). When a word would need
  less than 13 pt beside both left buttons, Paste last leaves the row for the
  cursor page and comes back only between words (`TypingBridge.fitEnds`). When
  a word would not fit a third of the bar even at 10 pt, as "Incomprehensible"
  on the iPhone SE and 17 Pro in portrait, two suggestions share the bar in
  halves, as Apple's bar does; a lone suggestion takes the whole bar. Tapping Paste last with nothing dictated yet
  shows "Nothing dictated yet" (without Full Access, "Allow Full Access to
  paste dictations"), in secondary text and announced to VoiceOver; the app's
  own notices stay red. In the middle,
  VoiceiQ's own items replace the suggestions while they show: "Open VoiceiQ
  to finish", a notice from the app, or the Dictionary offer. While a
  dictation runs, the recording strip (Cancel, time over the LevelGlow
  waveform, Done) takes the whole row until the text is delivered; Cancel
  and Done are the same size as the row's buttons.
- Hex's keyboard (`FullKeyboardView`, hosted by `TypingBridge`): the
  suggestion bar (predictions and the pending auto-correction), letters,
  123 and #+= layers, emoji with search, slide to type, the space-bar
  trackpad, accent pop-ups, smart punctuation and number pads for number
  fields. English only: `TypingBridge` pins the keyboard to English QWERTY
  (`languageOverride`, `HexLanguageSettings.swift`), so there is no language
  list, no space-bar language swipe or label, no second autocorrect language
  and no language detection, and only English data ships (the `en.hextm`
  word model, its `en.spellings` and the English emoji search index). Since
  Hex `f5819f4c` the model holds names, days and places ("Claude", "Monday",
  "London") and newer words ("ChatGPT"), so they can be swiped and typos of
  them are corrected; a correction to a name takes its capital, and
  `en.spellings` gives words their own spelling ("chatgpt" becomes
  "ChatGPT", "github" "GitHub"). English swipe no longer ranks names lower. The globe key shows only
  when iOS asks for one (`needsInputModeSwitchKey`), as on the iPhone SE.
- The edit panel (`EditPanel`, `EditController`), in place of the keys, in
  three rows of one height: line start, previous word, left and right chevrons
  that repeat while held, next word and line end; then copy, cut, paste (Full
  Access), Paste last dictation, undo and redo; under them the globe (only when
  `needsInputModeSwitchKey` is true), a blank space bar, delete and return. A
  dictation that starts closes it.

**VoiceiQ, not Hex.** VoiceiQ changes Hex's keyboard only through
`iOS/Keyboard/Sources/HexGlue` and the patches in `iOS/Keyboard/Hex/patches`:

- No Hex key or logo: `HexKeyPlacement.hidden` takes the Hex key out of every
  layout, so the suggestion bar spans the full width, and the bar's
  hold-to-dictate is off (`0001-voiceiq-keyboard.patch`).
- VoiceiQ's look: the return, go and send keys, the slide-to-type trail and
  the trackpad selection use VoiceiQ's accent (the Dictate pill's blue), and
  the keys have the 1 pt under-shadow of VoiceiQ's keycaps
  (`0002-voiceiq-style.patch`).
- With Learn how I type off, keeping a suggestion holds the word for the
  session only; Hex would otherwise save it to its learned words
  (`0004-voiceiq-learning-opt-out.patch`).
- Undo dictation deletes the dictation only when the text on both sides of it
  still matches what was there when it went in, so an earlier copy of the
  same words is never the one removed (`0005-voiceiq-undo-context.patch`).
- Hex's clipboard offer and the selection strip's Cut and Copy follow the
  keyboard's real Full Access (`KeyboardViewModel.hasFullAccess`, set in
  `TypingBridge.refreshHostTraits`). The Settings chip on Hex's Allow Paste
  notice opens `voiceiq://keyboard/settings`, and the app opens its own page
  in iOS Settings, where Paste from Other Apps is.
- While VoiceiQ shows its own content in the suggestion row (recording strip,
  notice, Dictionary offer, edit panel), Hex's strip stays hidden: the flag is
  stored and applied again each time Hex refreshes its strip, which covers the
  emoji panel closing and a selection ending
  (`0006-voiceiq-strip-refresh.patch`).
- Spatial autocorrect reads where each key was tapped, so "Hel" with the H
  tapped toward the G scored "Gel" above the typed word. A short start is now
  treated as an unfinished word (`AutocorrectEngine.unfinished`,
  `0009-voiceiq-unfinished-words.patch`): a three-letter start is
  extended only to a clear finish ("wil" to "will"; "Hel" stays, with Help
  offered but not highlighted, because help, hello and held are all likely;
  "th" still becomes "the"), and a 1–3 letter start is not swapped for other letters the
  model ranks below the best completion of what was typed. The same rule keeps
  such words out of the strip's other candidates. A missed space ("iam" to
  "I am") and words the model lacks, such as Dictionary names, are never held
  back. What the strip highlights is what space applies.
- A word the typing model spells with capitals inside it (`en.spellings`:
  ChatGPT, GitHub, iPhone, eBay) keeps that spelling at a
  sentence's start, typed, swiped or offered in the strip: the start-of-sentence
  capital goes only on an all-lowercase word, so "chatgpt" becomes "ChatGPT"
  and "iphone" "iPhone", never "Chatgpt" or "IPhone"
  (`0010-voiceiq-spelling-case.patch`).
- A secure field (`isSecureTextEntry`, including custom and web ones without a
  password content type) gets no auto-correction and nothing goes into the
  typing journal (`TypingBridge.autocorrectionType`,
  `0007-voiceiq-secure-journal.patch`).
- Off screen (`viewDidDisappear`), the keyboard closes Hex's emoji panel,
  drops the emoji library and saves the typing journal.
- VoiceiQ's Dictionary words reach Hex's vocabulary capped at 100; over the
  cap the newest are kept, so a word added from the suggestion strip is never
  the one dropped.
- Hex's in-keyboard dictation, its recording panel and Metal dot scope, the
  style menu, translation and model notices are permanent stand-ins that
  never show (`HexDictationStandIns.swift`). Hex's wording that names its app
  reads "VoiceiQ" (`iOS/Keyboard/Resources/en.lproj/Localizable.strings`).
- Hex's custom vocabulary is VoiceiQ's Dictionary: its words are never
  auto-corrected away, and holding a suggestion adds the word to the
  Dictionary.

Typing goes through `EditController` (`TypingBridge.insertText` and
`deleteBackward`), so undo covers typing, dictation and the edit panel alike.

**Updating Hex's keyboard.** `scripts/sync-hex-keyboard.sh --check` lists
Hex commits not synced yet; `scripts/sync-hex-keyboard.sh [ref]` replaces
everything `iOS/Keyboard/Hex/MANIFEST` lists, applies the patches in name
order and records the commit in `iOS/Keyboard/Hex/UPSTREAM`. Never edit files
under `iOS/Keyboard/Hex` by hand: change the glue, or add a patch made with
`git diff` after editing the synced file. The manifest leaves out the German,
Spanish and Norwegian emoji indexes and every typing model but English
(`es.hextm` is MPL 1.1; the others add about 24 MB).

**Recording strip** (`RecordingStrip`, `LevelGlow`), modelled on Gboard's
Rambler. In place of the shortcut row: Cancel (x) on the left, a red stop button on the
right, the elapsed time in the middle. Behind them a red glow rises from the bottom edge as loud
as the voice was: silence keeps 8% of the strip's height, and the height grows
linearly with the mic level up to the full strip for the loudest speech. It is
blurred, spans the strip's full width behind the buttons and fades out over
its bottom few points; its top edge is a smooth curve through
the recent levels, newest on the right. The app keeps the levels (`LevelBars`:
one per mic level it writes, at most every 0.06 s, smoothed with a fast attack
and slow release, newest 256 kept) and publishes them as
`SharedStore.levelBars`; the keyboard redraws every 0.06 s. A keyboard that
appears mid-dictation, after an app switch or after being hidden, shows the
dictation so far instead of starting empty. There is no live text: the words
arrive once the dictation is written. While the text is written the strip shows only a spinner
with "Writing…". Reduce Motion holds the glow flat at the
latest level. The glow is a plain `Shape` on a 0.06 s timer: a `Canvas`
inside `TimelineView(.animation)` drew in the Simulator but nothing on an
iPhone (0.6.23).

**Edits and undo.** Every edit the keyboard makes goes through
`EditController`: space, return, delete, paste, cut, and a dictation typed
into the field. It notes the exact text each edit removed and typed; each
undo step keeps the edit that reverses it and the edit that redoes it, so
undo and redo work in fields longer than the text iOS shows before the
cursor. A dictation is one step, a run of deletes is one step, and a run of
spaces and returns is one step. A selection the edit replaced comes back on
undo. Undo is cleared when the text changes outside the keyboard or the
cursor moves, because it replays at the cursor. A keyboard cannot select text
or reach the app's own undo.

**Add to Dictionary.** With Full Access, selecting text in the field shows
"Add “word” to Dictionary" in the suggestion row. The keyboard rereads the
selection after each of its own edits (`EditController.selection`), because
iOS does not report a keyboard's own edits to it. Text selected in another app
or elsewhere on screen is not visible to a keyboard: copy it, and the next
time the keyboard opens it offers "Add copied text to Dictionary".

**Instances and touches.** iOS makes a new `KeyboardViewController` each
time the keyboard appears. Nothing in the view tree may hold the controller
strongly, and its `deinit` detaches the SwiftUI view, which iOS otherwise keeps
alive through its trait collection; either leak kept every instance until iOS
ended the extension and showed its own keyboard. iOS also drops a keyboard's
touches on fully transparent pixels, so the SwiftUI root has a 1% gray
background.

**Memory.** The keyboard maps Hex's English typing model (`en.hextm`, 3.6 MB)
and loads the English emoji index when the emoji panel opens. Measured in the
iOS 27.2 Simulator (Debug, 2026-11-26): 31 to 37 MB after typing, the 123
layer, cursor control, rotation and the recording strip on the iPhone SE and
17 Pro, peaking at 44 MB with the emoji panel and a slide-to-type word. iOS ends keyboards near 60 to 70 MB.

**Learning.** Hex's "Learn how I type" is on, as in Hex: per-key tap offsets
and word-level fixes (`TypingJournal`) stay on the iPhone,
in the App Group and the keyboard's own container. Nothing is sent anywhere.
Settings › Keyboard & Permissions › Typing turns it off (Adaptive touch stays
on with it off) and erases what it learned (`TypingSettingsCard`), beside Auto-correction, Auto-capitalization,
Slide to type, Key haptics and Number row. The card writes Hex's own keys in
the App Group, which the keyboard reads each time it appears; Hex's other
switches (key colours, emoji shortcodes and its other Labs experiments) keep
Hex's defaults.

**Adaptive touch** (Hex's Labs › Adaptive touch, off by default in Hex) is
always on in VoiceiQ, with no switch (`0011-voiceiq-adaptive-touch-on.patch`).
The keyboard reads your taps against where you actually land on each letter
key, per key size, for auto-correction and suggestions; the keys and their
touch areas don't move. A profile takes 400 labelled taps over 3 sessions;
until then Learn how I type's own per-key offsets keep moving the centres, as
before (`FullKeyboardEngine+Keys.swift`, same patch). It learns nowhere a
secure field or one Learn how I type skips would be. Without Full Access it
keeps the averages in memory until the keyboard closes; with Full Access the
keyboard writes them to its own container each time it goes off screen
(`TypingBridge.disappeared`). Erase what it learned also writes Hex's
`adaptiveTouch.resetAt`, so a running keyboard drops older averages the next
time it reads them.

**Tests.** `KeyboardTests` (in the `VoiceIQiOS` scheme, hosted by the app so
the embedded keyboard's typing model loads) compiles the keyboard's sources
and Hex's against fake text fields: undo and redo of a dictation and deletes,
typing over a selection, word and line steps, an edit by the app dropping
undo, and spellings with inner capitals at a sentence's start, typed and
swiped through the real keys (`SpellingCaseTests`).

The earlier typing keyboard and the keyboard's Ask and Translate modes were
removed on 2026-11-22 (`activities/2026-11-22-mini-keyboard.md`); Hex's
keyboard came back in its place on 2026-11-26
(`activities/2026-11-26-hex-qwerty-keyboard.md`).

### Dictionary

Settings › Dictionary matches the Mac: search, add with "Write it as" and
"Heard as" labels that stay beside the fields, separate
Dictionary and Auto-learned sections (auto-learned words come from the Mac's
edits),
stars, swipe to delete, and CSV import and export from the ⋯ menu.

**iCloud sync.** The dictionary is the same on the Mac and the iPhone, with no
setting. `DictionarySync` (VoiceIQCore) keeps the whole dictionary as one iCloud
key-value storage value, `dictionary.v1`, in the store both apps share
(`com.apple.developer.ubiquity-kvstore-identifier` = `G8K3545FJ2.io.blue.voiceiq`).
Every local edit and every change from iCloud merges the two copies with
`DictionarySnapshot.merge` and writes the result to both sides:

- each entry carries `updatedAt`; the newer version wins;
- deletions are kept as tombstones for 180 days, so an older copy on another
  device does not bring a deleted word back;
- the same word added on two devices becomes one entry (the older one,
  starred if either was).

### Writing rules sync

The built-in writing rules (`PromptV1.rules`) ship with the app and are
not shown or editable, so an update changes them on every device. Settings
shows only "Custom rules", which the dictation prompt appends after the
built-in rules. The custom rules are the same on the Mac and the iPhone,
with no setting. `WritingRulesSync` (VoiceIQCore) keeps them as a second
value, `writingRules.v2`, in the same key-value store. The value is the
custom rules text (absent when there are none) and when it was last edited.
The newer edit wins (`WritingRulesSnapshot.merge`); clearing the rules is an
edit too, so it clears them on the other device.
`SettingsStore.setCustomWritingRules` stamps an edit only when the text
changes. Rules that were never stamped count as the oldest edit; when two
such copies meet, custom rules win over none.
While iCloud shows no value, only an edit made just now is uploaded, unless
the store holds `writingRules.v1`, which older builds wrote only after
comparing with iCloud or after an edit on that device: until
its first download finishes a device sees no value even when iCloud holds a
newer one, and writing an older copy then could replace it. An older copy
goes up once the stored value can be compared, or with the next edit.
Builds before the split kept the full editable rules in `writingRules.v1`;
new builds never read it. On first launch,
`FormattingSettingsMigration.splitWritingRulesOnce` turns a saved full copy
into custom rules: it drops every line of any earlier default and keeps the
rest. The edit time moves to the new key even when nothing is left, so a
reset still counts as the newest edit.
The value is capped at 64 KB so the dictionary keeps most of the 1 MB store.

### History sync

Meetings sync the same way, also with no setting; see MEETINGS.md, Sync
through iCloud. Mac meetings show under Notes on the iPhone with their
chat, and questions asked on either device appear on both.

History's final text is the same on the Mac and the iPhone, with no setting.
`HistorySync` (VoiceIQCore) keeps one `Dictation` record per finished
dictation in the `History` zone of the private CloudKit database of the
container both apps share (`iCloud.io.blue.voiceiq`), through `CKSyncEngine`.
A record holds the final text (`displayText`: the cleaned text, or the raw
transcript when nothing was cleaned), the start time, the length, the app
name, the device name and the status. Audio, the "As heard" transcript,
errors and token usage stay on the device that dictated.

- A dictation is uploaded once its status is final (`inserted`,
  `copiedToClipboard` or `recovered`; `HistoryStore.pendingUploads`).
  `cloudSyncedAt` on the row marks it as uploaded. A Retry that changes the
  text or status clears it, so the row uploads again over the same record:
  CloudKit answers the first save with `serverRecordChanged`, and the engine
  saves our fields on the server copy it returned. The other device replaces
  its copy's text.
- Rows from the other device arrive with `origin` (its name) and no folder.
  History shows them like any other dictation; the detail view says
  "Dictated on <device>". They have no Retry and no "As heard".
- Deleting a row (swipe, Discard, Delete All) deletes its record, and the
  other device removes its copy, folder included. The retention purge is
  local and leaves iCloud alone, so an old dictation purged on the iPhone
  stays on the Mac.
- Signing out of iCloud removes the other device's rows and forgets which
  local rows were uploaded; signing in again uploads them. A deleted zone or
  a switched account does the same and starts over.
- The engine's state lives in `history-sync-state.json` next to
  `history.sqlite`. `refresh()` fetches on every return to the foreground,
  because a suspended app receives no push.
- On the Mac, Debug builds have no container entitlement, so `HistorySync`
  checks `com.apple.developer.icloud-container-identifiers` at launch and
  stays off without it. Release builds need the Developer ID profile with
  the container (see RELEASING.md).

iOS delivers no iCloud change while the app is suspended, so the app also
merges when it becomes active (`DictionaryBridge.appBecameActive`). Without an
iCloud account the dictionary stays local and uploads once one is signed in.
Key-value storage holds 1 MB; a dictionary over 900 KB stays on the device and
the session log says so.

**Adding from the keyboard.** When text is selected in the field the keyboard
is typing into, the keyboard shows "Add “…” to Dictionary" in the suggestion row
(or "“…” is in your Dictionary"). A keyboard can see only its own field, so
text selected anywhere else (a web page, a message) comes in through the
clipboard: after a copy, the next time the keyboard opens it shows "Add copied
text to Dictionary" with the system paste button, which reads the clipboard
without a paste prompt. Only one line of 1–60 characters is accepted, the
dictionary's own limit. Results VoiceiQ itself put on the clipboard are not
offered (`SharedStore.appPasteboardChangeCount`).

The keyboard queues the word in the App Group (`SharedStore.dictionaryAdditions`,
keyboard-written) and pings `DarwinNotifier.Name.dictionary`; the app adds it
(`DictionaryBridge`), remembers which queued IDs it handled in its own
defaults, and publishes the lowercased word list back
(`SharedStore.dictionaryTerms`, app-written) so the keyboard knows what is
saved. A word queued while the app is suspended is added when the app next
runs. Everything needs Full Access.

## Feature parity with macOS

| macOS | iOS |
| --- | --- |
| Dictation key, hands-free | Mic button in the keyboard |
| Pill | Keyboard status plus Dynamic Island |
| AX and paste insertion | `textDocumentProxy.insertText` |
| Paste last | Paste last |
| AssemblyAI API key | Same, in Settings › API Key and the iOS Keychain. The key card shows an SF Symbol tile (`BrandTile`) |
| History stats: words, dictations, WPM, audio time, time saved, day streak, with a period menu | Statistics (`StatsView`), opened from the row above History's days or from Home's stats grid. Same `HistoryStore.stats(period:)` and the same remembered period (`historyStatsPeriod`); the Mac's streak tooltip (longest streak, active days) is a line under the tiles. Home's grid shows all time |
| Dictionary with search, CSV and Auto-learned | Same, synced through iCloud, plus adding a selection or a copied word from the keyboard |
| Custom rules; spelling from the region | Same: custom rules in Settings › Dictation, spelling from the iPhone's region |
| `[transcription] timing:` and `[session] timing` debug log lines | Same lines, in the app's debug log file |
| Microphone picker | Microphone: Automatic, iPhone or Bluetooth (see the voice session section) |
| History, retry, crash recovery, retention | Same. The detail shows Pipeline, the seconds from Stop to the text being ready (`DictationRecord.pipelineSeconds`, as on the Mac; absent for dictations synced from the Mac), the cost and one row per stage and model (stage, model, call count when above one, summed cost; `UsageLine.lines` over `UsageStore.records(forSession:)`), and Copy turns into "Copied" with a checkmark and a success haptic for 1.5 s |
| Cost for AssemblyAI (plus Gemini, OpenAI, ElevenLabs or Claude while History has calls booked to them), periods and Detailed | Same |
| Advanced: Writing model | Same, plus the session log |
| Language picker in Settings › Dictation | Same, in Settings › Dictation |
| Screen context | Not on iOS: an app cannot capture other apps' screens (`PlatformStubs+iOS.swift`) |
| Text around the cursor sent with each dictation | Same, from prose fields: the keyboard sends it with Dictate and Stop (`KeyboardCommand.surroundingText`) |
| Learning from your edits | Not yet: needs the keyboard to read the field again after the text lands |
| Call detection, names read from the call screen | Not on iOS: an app cannot see other apps' microphone use, screen or windows |
| Mute other audio, pause Music and Spotify, sounds, resting indicator, hide pill from screen sharing, copy recovered dictations | Not on iOS |
| Shortcuts (Paste last transcript, Meeting recording) | Paste last in the keyboard; Record in Notes |
| Not on the Mac | Keep mic on after dictating, Action Button |

## Building

```bash
./scripts/build-ios.sh                              # Simulator, ad-hoc signed
./scripts/build-ios.sh DEVICE=1 DEVELOPMENT_TEAM=XXXXXXXXXX
```

A device build needs the App Group from `project.yml` registered for all
three bundle IDs under your team.

### Apple Developer setup

The team needs the App Group, three App IDs with App Groups enabled and
assigned, an App Store profile for each App ID (named as in the
`PROVISIONING_PROFILE_SPECIFIER` settings in `project.yml`), an Apple
Distribution certificate, and an App Store Connect app record.

If a capability changes, the three profiles are invalidated and must be
regenerated in the portal under the same names.

### TestFlight

```bash
./scripts/release-ios.sh                # test, archive, verify, upload with asc
UPLOAD=none ./scripts/release-ios.sh    # stop before the upload
```

The steps, the one-time asc and signing setup, and the Xcode upload fallback
are in [RELEASING.md](RELEASING.md#iphone-testflight). `ITSAppUsesNonExemptEncryption`
is `false`, so builds skip the export-compliance question.

## Known limits

- The host-app resolver, the arbiter swizzle and `AppLauncher` are private
  API. App Review may reject them; if it does, delete `HostArbiterActivation.m`
  (the resolver returns nil) and make `AppLauncher.open` return false. Both
  fall back to return URLs and the swipe-back screen. `AppLauncher` is
  verified in the simulator only so far.
- iOS ends a Live Activity after eight hours. The session stays up, and the
  next mic tap bounces once to start a new activity.
- The orange mic dot shows for the whole warm window after a dictation.
- The Action button control needs iOS 18 and Live Activities turned on.
- On an iPad with a keyboard case, a dictation lands on the clipboard, not in
  the field: iPadOS hides third-party keyboards while a hardware keyboard is
  attached, so nothing can type it in place.
- The first dictation after a cold start costs one trip to the app.
- A keyboard cannot recognise a field it has left. After a return, the text
  is typed only when the app and the field's text match, or into the first
  empty field of that app that a keyboard comes up in after Stop. In an app
  with several empty fields (two empty chats), that can be the wrong one:
  stop in one chat, dismiss the keyboard, and open the other chat first. The
  text is typed, never sent.
- After Stop, a visit to another field of the app turns a typed result into
  an offer, also when the user ends up back in the first empty field. So does
  a keyboard dismissed and brought back within one second.
- An address, code or number field gets its text typed only when Stop was
  tapped in it and the keyboard never left. After a return it gets the offer.
- A field that the user edited while the text was being written no longer
  matches, so the result is offered through Paste last and not typed.
- Background recording across an app switch, the Live Activity buttons in
  the Dynamic Island, and Copy from a locked phone are verified in the
  Simulator only. The Simulator has no real microphone, no jetsam and no
  Dynamic Island hardware.
- Keys make no sound and no haptic tap: neither worked reliably from the
  extension, so both were removed (2026-10-30).
