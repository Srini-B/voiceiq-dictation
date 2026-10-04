# VoiceiQ for iOS

A voice-only keyboard backed by the same dictation pipeline as the Mac app.
The keyboard never records or calls a model. It sends commands to the VoiceiQ
app, which records, transcribes with your own API key, and hands the text back.
Like the Mac, it runs Gemini or OpenAI models, with that provider's own key or
through OpenRouter or Vercel AI Gateway.

## Targets

| Target | Contents |
| --- | --- |
| `VoiceIQiOS` | App: onboarding, keys, settings, history, meetings, background voice session |
| `VoiceIQKeyboard` | Keyboard extension (`RequestsOpenAccess`), links `VoiceIQBridge` only |
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
   └──────snapshot + Darwin ping ◀── App Group ◀───────┘ → Gemini / gateways
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
   session's Live Activity is on screen and no background start has failed
   since the app was last opened.
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
   under "Keyboard" in Settings › Advanced › Session log.

Ask shows the answer in a panel with Insert and Copy. Translate inserts the
translation into the target language from Settings › Dictation.

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

`KeepAliveAudio` sets a `.playAndRecord` session (mix with others, A2DP; HFP
only when "Use iPhone microphone" is off), plays silence and taps `inputNode`
without keeping the buffers. Each dictation builds its own capture engine
(`AudioCaptureEngine`), which runs alongside it.

The session ends when the user taps End (app or Dynamic Island) or when an
audio interruption cannot be resumed. There is no idle timeout. A call or Siri
interruption finalizes an in-progress dictation, so the words are kept.

iOS lets a backgrounded app start recording only while it is already
recording. Measured on device: silent playback alone and a Live Activity both
failed at the second in-place start; a visible Picture in Picture window
worked, but iOS gives the app no way to hide it (the only client-to-system
PiP calls are start, stop and size). So the keep-alive engine also runs a
discarding tap on `inputNode`: while a session is up the mic is open and the
orange dot shows, and each dictation's capture engine starts alongside it.

The session lasts for the warm window after each dictation, set in
Settings › Dictation › Keep mic on after dictating (`MobileSettings.warmWindow`:
Never, 5 s, 10 s, 30 s default, 1 minute). The window counts from when the
text is delivered; "Never" closes the mic as soon as recording stops but keeps
the session up (on background time) until the text is delivered, so the
keyboard and the Dynamic Island show "Writing…" in between. Settings ›
Dictation has an "Open Action Button settings" button (`App-prefs:ACTION_BUTTON`,
falling back to VoiceiQ's page in Settings). When it runs out the mic
closes and the next keyboard tap bounces through the app again.

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

### iPad

The app and both extensions target iPhone and iPad (`TARGETED_DEVICE_FAMILY`
`1,2`). The iPhone stays portrait; the iPad supports every orientation, so it
runs full screen, in Split View and in Stage Manager windows.

Layout follows the horizontal size class, not the device:

- Regular width (an iPad window wide enough): History, Meetings and Settings
  use `ListDetailNavigation`, a `NavigationSplitView` with the list on the
  left and the selected item on the right. Neither column shows a title or
  a bar background: the tab bar above names the page, and in Settings the
  open section's row is tinted in the sidebar (`List(selection:)` over
  `SettingsSection`). Pages pushed inside the detail column keep their
  title and back button. Home puts the session, setup and
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
the user presses ⌘V. On iPad, Home, onboarding's Try it page and
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

Onboarding has four pages: welcome, API keys (every provider plus the optional
ElevenLabs and TinyFish keys on one page, with a provider picker once two or
more keys are saved and a Transcription provider picker once an ElevenLabs,
OpenRouter or Vercel key is), permissions
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

### Meetings

Meetings run in the app like a recorder: Record meeting, the phone records the
room with the mic, Stop, then `MeetingEngine` transcribes and writes notes. The
Live Activity shows the running time with a Stop button. iOS does not allow
recording other apps' or call audio, so `SystemAudioTap` writes an empty
`system.caf` and the pipeline treats every meeting as in-person: there is no
far-side reference, so `MeetingTranscriber.callAudio` skips echo cancellation
(the WebRTC AEC3 xcframework ships a macOS slice only and is not linked on
iOS). Speaker linking, meeting-type notes, suggested speaker names and Redo
(notes only, or transcript and notes) work as on the Mac. Dictation is refused
while a meeting records.

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
| Provider (Gemini or OpenAI), ElevenLabs transcription, gateways under Experimental, TinyFish | Same, in Settings › Provider & Keys and the iOS Keychain |
| History stats: words, dictations, WPM, audio time | Home's stats grid |
| Dictionary with search, CSV and Auto-learned | Same, synced through iCloud, plus adding a selection or a copied word from the keyboard |
| Writing rules, smart transcription, live, noise handling | Same settings |
| History, retry, crash recovery, retention | Same |
| Cost with the provider toggle, periods and Detailed | Same |
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
- The orange mic dot shows for the whole warm window.
- The Action button control needs iOS 18 and Live Activities turned on.
- On an iPad with a keyboard case, a dictation lands on the clipboard, not in
  the field: iPadOS hides third-party keyboards while a hardware keyboard is
  attached, so nothing can type it in place.
- The first dictation after a cold start costs one trip to the app.
