# VoiceiQ for iOS

A full English typing keyboard with VoiceiQ dictation, Translate and Ask on
one tap. The keyboard never records or calls a model. It sends commands to the
VoiceiQ app, which records, transcribes with your own API key, and hands the
text back. Typing runs entirely inside the keyboard, offline.
Like the Mac, it runs Gemini or OpenAI models, with that provider's own key.

## Targets

| Target | Contents |
| --- | --- |
| `VoiceIQiOS` | App: onboarding, keys, settings, history, notes (meetings), background voice session |
| `VoiceIQKeyboard` | Keyboard extension (`RequestsOpenAccess`), links `VoiceIQBridge` only; English typing with the word list in `iOS/Keyboard/Resources` |
| `VoiceIQLiveActivity` | Dynamic Island and lock-screen Live Activity |

All three share one App Group. Bundle IDs, the App Group and profile names
are in `project.yml`. The app declares
`UIBackgroundModes: audio` and `NSSupportsLiveActivities`, and handles the
`voiceiq://` scheme. Minimum iOS is 17 (Live Activity buttons need
`LiveActivityIntent`).

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
   └──────snapshot + Darwin ping ◀── App Group ◀───────┘ → Gemini / OpenAI
```

`VoiceIQBridge` defines the protocol:

- `KeyboardCommand` (`start` with a mode, `stop`, `cancel`), written only by the keyboard.
- `SessionSnapshot` (`off`, `warm`, `recording`, `processing`, plus the last
  `Delivery` and `Notice`), written only by the app.
- `ActivityRequest`, written only by the Live Activity buttons.
- A heartbeat the app writes every second while a session is up.

Every key has one writer, so nothing is locked. Darwin notifications
(`io.blue.voiceiq.bridge.command`, `…state`) carry no data. They only mean
"reread the App Group". Both sides also reread on their own lifecycle events,
because pings are dropped while a process is suspended.

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
4. Stop sends `stop`. The app transcribes, writes a `Delivery`, and pings.
   Whichever app the keyboard is in when the result arrives gets it, even when
   the dictation started in another app: the user stopped it there. The
   keyboard inserts the text with `textDocumentProxy.insertText`, adding a
   space when it would run into the previous word. Only the keyboard instance
   on screen may type: iOS can keep an earlier instance alive in the same
   process, still polling, with a text connection that reaches no field. The
   keyboard that types a result marks it handled (`insertedDeliveryID`).
5. Two seconds after delivering, the app checks `insertedDeliveryID`. If no
   keyboard typed the result (the keyboard was closed, or the user is on a
   screen with no text field), the app puts it on the clipboard and marks it
   handled, so a keyboard opened later doesn't type it too. Paste last always
   has it. The keyboard's decisions go to `SharedStore.keyboardLog`, shown
   under "Keyboard" in Settings › Advanced › Session log. Every line of
   that log, the app's and the keyboard's, starts with the date and time
   (`SharedStore.logStamp`, "2026-10-22 06:52:04", device time zone).
6. If the heartbeat stops while the snapshot says `processing`, iOS suspended
   or ended the app mid-dictation (a first on-device load after an iOS update
   or a long break can take minutes). The keyboard keeps the spinner and shows
   "Open VoiceiQ to finish" (`KeyboardModel.needsAppToFinish`); a tap opens
   `BridgeURL.app`. A suspended app resumes the dictation; an ended one
   recovers the saved recording at launch. The session log records each
   dictation's processing time and whether the app was in the foreground
   ("processed in 94.2s (background)"), and when the app was opened during
   processing.

Ask shows the answer in a panel with Insert and Copy. Translate inserts the
translation into the target language from Settings › Dictation (the iPhone
picker sets the first of the Mac's up-to-three targets; the others are kept
and used when the first matches the spoken language). Settings › Privacy has
the same "Keep dictations" picker as the Mac (`transcriptRetentionDays`);
`AppModel` runs `RetentionPolicy.purge()` on launch.

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
   `KnownAppSchemes` table.
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
It disables Auto-Lock while VoiceiQ is in front, and restores it when no active
dictation or meeting recording remains. It cannot control Auto-Lock in the
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
session (default to speaker, A2DP, mix with others; HFP only when "Use
iPhone microphone" is off) and taps `inputNode` without keeping the buffers,
so the mic stays open and the orange dot shows. `VoiceSession.isActive` says
whether it is up. It lasts `MobileSettings.warmWindow` after each dictation
(Settings › Dictation › "Keep mic on after dictating": Never, 5 s to 12 h,
default 30 s; key `warmWindowSeconds`), counted from when the text is
delivered; Home shows "Turns off in" with the countdown. With "Never" the
session ends once the text is delivered, so the next keyboard tap opens
VoiceiQ again. The audio session stays open until then: it is what keeps iOS
from suspending the app while a slow transcription runs (a first on-device
load can take minutes), at the cost of the mic dot showing until the text
arrives.
`AudioCaptureEngine` never configures the session, so each dictation's capture engine records into it.

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
dictation, and the result has no host app, so whichever field has the
VoiceiQ keyboard within two minutes receives it. Keyboard-started sessions
have no Live Activity.

The control is a `ControlWidgetToggle`, on while a dictation records. Its
value provider reads `SharedStore.isDictating()`, which is the snapshot phase
`recording` with a live heartbeat. `VoiceSession.publish` calls
`ControlCenter.reloadControls(ofKind:)` each time the phase enters or leaves
`recording`, so the control stays lit for the whole dictation and should turn
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

Onboarding has four pages: welcome, API keys (a Gemini or OpenAI provider
picker with that provider's key, plus the optional TinyFish key), permissions
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
while notes record. With **Notes transcription** set to On device and Fluid
Speech Mini downloaded, the recording is transcribed in process after Stop as
one speaker; there is no diarizer, real-time path, or Nemotron on iOS (see
[On-device meetings](LOCAL_TRANSCRIPTION.md#on-device-meetings)).

### Typing

The keyboard opens on letter keys. A bar above them shows three suggestions,
with the VoiceiQ button (waveform) on the left and the mic on the right. The
mic starts a dictation at once; the waveform opens the voice panel with
Dictate, Translate and Ask. A running dictation shows the recording panel
until the text is delivered, then the keys come back.

**Recording panel** (`RecordingPanel`, `LiveWaveform`). A red waveform fills
the panel while recording: one bar every 0.06 s from `SharedStore.level`, which
the app writes on each mic level callback. Bars rise fast and fall slowly,
scroll right to left and fade with age. Below it: cancel (x), the elapsed
time with the mode ("Listening", "Listening to translate", "Listening to your
question"), and a red stop button that finishes the dictation. While the text
is written the bars turn blue and a slow pulse runs across them with
"Writing…" or "Thinking…"; the buttons hide. Reduce Motion freezes the bars.

**Add to Dictionary.** With Full Access, selecting text in the field replaces
the suggestions with "Add “word” to Dictionary". Text selected in another app
or elsewhere on screen is not visible to a keyboard: copy it, and the bar
offers "Add copied text to Dictionary" until you start typing.

| Feature | How |
| --- | --- |
| Layouts | QWERTY, QWERTZ, AZERTY, Dvorak, Colemak (`KeyLayout`). English words on each. Optional number row; Short, Default or Tall height (`KeyboardViewController.height`). Without the number row, holding a top-row letter types its digit (shown in the key's corner) on the 10-key layouts. |
| Pages | Letters, 123, #+=, number pads for number, decimal and phone fields. Email fields get @ and `.`, URL fields `.` and `/`; search fields keep a full space bar. Return shows the field's label (go, send, search…). |
| Keys | Shift (tap once, double-tap for Caps Lock, hold and type), accents and alternates on long press (hold `.` for `.com`, the currency key for other currencies), key preview, repeat delete that moves to whole words, space-bar cursor drag. A touch goes to the nearest key in its row. |
| Suggestions | Next-word predictions from word pairs, completions, and corrections. The typed letters show in quotes; picking them keeps and learns the word. |
| Auto-correction | Delete right after a correction restores the typed word and learns it. On space or punctuation. Fixes a mistyped word one edit away (adjacent keys cost less), two edits away through `UITextChecker`, apostrophes (`dont` → `don't`), and capitals (`i` → `I`, `monday` → `Monday`). A real word is never replaced by another word. Off in URL, email and search fields and where the field turns it off. |
| Auto-capitalization, “.” shortcut | Sentence starts, per the field's `autocapitalizationType`. Two spaces type a period. |
| Slide to type | `SwipeClassifier` (ported from FlorisBoard). The slid word gets its space when the next word starts, so punctuation attaches; the bar offers the other candidates; delete removes the whole word. |
| Your words | The VoiceiQ Dictionary (`SharedStore.dictionaryWords`), contact names and Text Replacements (`requestSupplementaryLexicon`), and words typed twice or picked from quotes. |
| Emoji | Unicode's list in CLDR order, by category, with recents. |
| No assistance | Password, one-time code, card, phone and postal code fields. |
| Themes | Default, Clear, Physical, Mechanical and iOS 5, after the Raycast keyboard (`KeyTheme`). Physical and Mechanical take Automatic, Light or Dark keys, which pins the whole keyboard through `overrideUserInterfaceStyle`; iOS 5 is always light. Themes with their own background cannot paint the system's globe and mic strip below the keys. |
| Sound and haptics | Key Sound plays the iOS keyboard's click, delete and modifier sounds (`AudioServicesPlaySystemSound` 1104, 1155, 1156), which follow the ring/silent switch. Haptic Feedback (off by default) needs Full Access and keeps one prepared generator. |

Key labels are centred on the cap height, or the x-height for lowercase, not
on the font's line box. A slide starts once the finger reaches another letter
(at least a third of a key away) or moves three quarters of a key; moving
more than 8 pt cancels the long press for accents. A slide shorter than 1.6
keys that ends within 0.15 s is a sloppy tap and types its first key. The slide
trail draws above the keys.

**Data.** `lexicon.bin` holds 82,846 words and 242,342 word pairs (3.5 MB),
memory-mapped so it does not count against the extension's memory limit. A
word's key is lowercase without apostrophes, so one binary search finds `dont`
and `don't`. `scripts/generate-keyboard-data.py` rebuilds it and `emoji.txt`
from pinned sources (THIRD_PARTY_NOTICES.md, "Keyboard data").

**Scoring.** Every candidate gets ln P(word | previous word), using the pair
when the list has it and the word's frequency times 0.05 when it does not,
plus the log cost of the edits from what was typed. On space, an unknown word
becomes the best different spelling scoring above −24. A known word changes
only to its own contraction or capitalization.

**Settings.** Settings › Typing in the app writes `KeyboardPreferences` to the
App Group: layout, predictions, auto-correction, auto-capitalization, slide to
type, “.” shortcut, key sound, haptics, and Reset Keyboard Learning. The
keyboard reads them each time it appears. Without Full Access iOS hides the App
Group, so the keyboard uses the defaults. Learned words stay in the keyboard's
own storage.

**Measured** (2026-10-30, Mac harness over the same engine): 30 of 33 common
misspellings corrected as the iOS keyboard does, about 7 ms a suggestion. Slide
to type on simulated noisy paths for 400 words drawn by frequency: 357 right
first and 389 in the top three at 0.15 key-width noise; 302 and 355 at 0.30;
under 1 ms a gesture.

### Dictionary

Settings › Dictionary matches the Mac: search, add with "Heard as", separate
Dictionary and Auto-learned sections (auto-learned words come from the Mac),
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

The built-in writing rules (`DefaultWritingRules`) ship with the app and are
not shown or editable, so an update changes them on every device. Settings
shows only "Custom rules", which the cleanup prompt appends after the
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
is typing into, the keyboard shows "Add “…” to Dictionary" under the mic bar
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
| Ask Anything, Translate, Paste last | Keyboard modes and Paste last |
| Provider (Gemini, OpenAI, or Claude + Nemotron with an Anthropic and a DeepInfra key), TinyFish | Same, in Settings › Provider & Keys and the iOS Keychain. Each key card carries the service's favicon from `Assets.xcassets/Provider*.imageset` (`BrandTile`); the OpenAI and Anthropic marks are template images so they take the ink colour in dark mode |
| Transcription and Meeting transcription pickers (On device, provider) | Same; the second is **Notes transcription**, each in its own section because an iOS Form hides a segmented picker's label |
| History stats: words, dictations, WPM, audio time | Home's stats grid |
| Dictionary with search, CSV and Auto-learned | Same, synced through iCloud, plus adding a selection or a copied word from the keyboard |
| Writing rules, smart transcription, live, noise handling | Same settings |
| On-device transcription: Fluid Speech Mini and Nemotron 3.5, English tools, live preview with Fluid Speech Mini | Fluid Speech Mini and English tools only, in-process; no live preview (see [local transcription](LOCAL_TRANSCRIPTION.md)) |
| History, retry, crash recovery, retention | Same. The detail shows the cost and one row per model call (stage, model, cost) from `UsageStore.records(forSession:)`, and Copy turns into "Copied" with a checkmark and a success haptic for 1.5 s |
| Cost with the Gemini and OpenAI toggle, periods and Detailed | Same |
| Advanced: the selected provider's models | Same, plus the session log |
| Screen context, auto-learn, shortcuts, call detection, mute other audio, sounds | Not on iOS |

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
- Typing is English only. Predictions come from book text, so chat phrasing
  ranks lower than on Apple's keyboard until the keyboard learns it.
- Haptics need Full Access; iOS mutes a keyboard's haptics without it.
