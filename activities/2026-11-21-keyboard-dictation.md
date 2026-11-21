# Dictation inside the iPhone keyboard

**2026-11-21.** The product owner asked to bring back dictation inside the
keyboard, on top of Hex's keyboard (branch `hex-keyboard`): the keyboard
records through a hidden `WKWebView`, and VoiceiQ never comes to the front.
It starts from the closed PR #53 (our pipeline running in the keyboard) and
ports the behaviour of Hex's `KeyboardLocalDictation` (MIT) into our own
code. Hex's vendored files are unchanged. How it works is in
[docs/IOS.md](../docs/IOS.md#dictating-in-the-keyboard).

## Why

The app switch before a cold dictation was the slowest and most visible step
of dictating on the iPhone. With the warm "Keep mic on" session it went
away only for a while after each dictation.

## Decisions

- **Same pipeline as the app.** The keyboard runs `DictationCoordinator`
  with `WebMicCapture` as its `AudioCapturing`, so providers, Real-time,
  writing rules, dictionary, Translate and Ask are not duplicated. A warm
  app session still takes the tap; the app is also the fallback.
- **One accepted gap.** Recording stops when the keyboard hides. The text is
  held: typed into the same field within 30 s, otherwise offered in the
  strip for 10 minutes (Hex #2163). Same-field detection also accepts a
  renamed field in the same app with the same text before the cursor,
  because iOS gives the field a new ID when its app returns.
- **Background transcription without a second request path.** The keyboard
  captures the request the normal service would send
  (`GeminiClient.capturesTranscription`) and hands it to its own background
  `URLSession` in the App Group. The app replays the saved answer through
  the same service (`GeminiClient.replayedTranscription`), so parsing,
  usage, the writing model and History behave as for a normal dictation.
- **Never sent twice.** When iOS's time runs out, the coordinator cancels
  the keyboard's own request and its retry before the background upload
  starts, and nothing is handed over once the provider answered or the
  audio streamed live. The app does not re-send a recording whose
  background answer it already has. Decided after review on 2026-11-21.
- **Keys in the App Group keychain**, as #53 did. Every process with the App
  Group entitlement can read them (app, keyboard, Live Activity); docs/IOS.md
  states the risk.
- **Codex's #53 review fixes:** Cancel waits for the coordinator's
  keep-or-delete before handing the folder over, and "Never keep audio"
  applies in the keyboard.
- **Fixed during testing:** reading `documentIdentifier` while focus moves to
  a field that refuses custom keyboards crashed the keyboard (iOS returns nil
  for a non-optional UUID); it is now read without bridging. The background
  session's request timeout was raised to 120 s; the 60 s default dropped a
  slow answer.

## Verification

Simulator (iPhone, iOS 27), Messages in front, transcription against a local
mock of the Gemini API (no real key on the test Mac): Hex key and mic
dictation, Translate, Ask, Cancel, hiding mid-recording (text typed on
return, or offered and pasted), the background session finishing in a
relaunched app, the stop request from the Control Center path, the fallback
to the app, and a warm app session taking the tap. Release footprint of the
keyboard: 40 MB idle, 42 MB after typing, 45 MB recording, 47 MB recording
an Ask (hex-keyboard: 31 / 38 / 41 MB).

Not verified: a real provider, the lit control in Control Center (the
Simulator's Control Center could not be opened), music resuming, a real
device's memory limit, and offline behaviour (the test machines' network
must not be turned off).

## Rollback

Revert the branch's commits. Keys stay readable in the App Group keychain;
the app still reads them there.
