# Privacy

## The promise

Your voice goes from your Mac directly to Google's Gemini API
(`generativelanguage.googleapis.com`), using your own API key. Dictation,
meetings and screen context all use it by default, and VoiceiQ sends nothing
to any other model service. You can instead transcribe dictations and
meetings on your Mac, iPhone or iPad (Settings → Dictation → Speech, see
[ON_DEVICE.md](ON_DEVICE.md)). For what is transcribed on device, "Writing
rules and notes" decides what Gemini gets. Set to Gemini, it gets the
transcript text (with screen-context screenshots, if screen context is on),
and the audio only if the on-device model is missing, busy or fails. Set to
On device, it gets nothing while the on-device models work; if one is
missing, busy or fails and a key is stored, Gemini gets the audio (or, when
only the on-device writer failed, the transcript text) as it would with
Gemini. Set to Off, nothing transcribed on device goes to Gemini for
writing, but a recording the on-device models could not transcribe still goes
to Gemini as audio when a key is stored. Finished text still syncs to your own iCloud like any dictation
(see iCloud below). A row of
Speech left on Gemini (say, Dictation while Meetings are on device) still
sends that audio to Gemini. Models download from Hugging Face only when you ask for them.
There is no VoiceiQ server, no account, no analytics, no telemetry.
Everything else stays on your Mac. The code is open — verify all of this.

With no usable key, nothing is sent and the recording stays on your Mac.

## What leaves your machine (the complete list)

1. **Each dictation**, in one request to Gemini after you stop. Nothing is
   sent while you speak. The request holds the FLAC-compressed recording
   and the dictation prompt, and the model answers with the finished text.
   The prompt contains the built-in writing rules, your custom rules from
   Settings → Dictation, the spoken languages you set, the regional spelling
   of your Mac (read from its region for each dictation), the frontmost
   app's name and the title of its focused window (a document name, a page
   title, a chat name), in Safari, Chrome, Edge, Brave, Vivaldi, Arc, Dia,
   Opera, Firefox and Zen the host and path of the page in that window
   (never the query string or fragment, so no search terms or tokens), and
   up to 300 characters before the cursor and 100 after it in the field you
   are dictating into. No tone or category is derived from the app; the
   model reads intent from your speech and uses the app and window names
   only to tell what kind of text this is and how names on screen are
   spelled.
2. **Your dictionary terms**, in that same request. The model uses them to
   bias what it hears, which is why names and jargon come out spelled right
   as you speak rather than being corrected afterwards. Up to 100 words and
   up to 10 "heard as" spellings (the misspelling and its correction) are
   sent.
3. **Screen context**, while "Screen context" is on in Settings → Dictation — off
   by default since 2026-10-13 (three images added about 1.3 s to every
   dictation; the app and window names in item 1 replace them). VoiceiQ
   captures the main display when dictation starts and when the frontmost
   app changes during that dictation. It sends up to four reduced-size JPEG
   images in the same dictation request. VoiceiQ keeps the images in memory
   and never stores them on disk. macOS asks for Screen Recording permission
   the first time this feature runs. If you deny access, dictation continues
   without images. Turn off "Screen context" to stop capture.
4. **Meeting audio**, only after you start a recording. With "Offer to record
   calls" on in Settings → Dictation (on by default), VoiceiQ watches which
   processes use your microphone (Core Audio's per-process list; nothing is
   recorded). It offers to record when a calling app (Zoom, Teams, FaceTime,
   WhatsApp, Slack, Discord, Webex, Telegram, Signal and others), the system's
   FaceTime and iPhone-call service, or a browser tab on a meeting site uses
   the microphone, or when any other app or browser page both uses the
   microphone and plays sound, which is what a call looks like. The offer
   shows in the pill. To tell a meeting page apart, it reads the browser's
   window titles and page addresses through the Accessibility API. Nothing is recorded until you accept it, press the meeting
   shortcut (⌥M by default), or start one from Settings → Meetings. While
   recording, VoiceiQ writes two tracks to
   `~/Library/Application Support/VoiceiQ/meetings/` and sends nothing. On a
   detected call, they are the microphone the call uses and the sound of the
   call app alone; other apps, music and notifications are not recorded. In
   a browser call that is the browser's sound, so other tabs of the same
   browser that play sound are recorded too. When the call app has no audio
   open as the recording starts, the recording falls back to all system
   sound and the default microphone, as with no call. A
   recording with no call detected records the default microphone and all
   system sound.
   Recording stops only when you stop it; the stretches with speech are then
   sent to Gemini for a speaker-labelled transcript. That transcript is sent
   back to Gemini, with your dictionary terms and custom rules, for a summary
   and action items. Turn the setting off and no call detection runs.
   While a meeting records on the Mac, VoiceiQ reads names off the call
   window to name its speakers. With Screen Recording granted (asked during
   onboarding, optional), it takes a snapshot of the call window every 3
   seconds. It captures only a window of the call app, never the whole
   display; in a browser, only a window whose title is a meeting page. A
   recording with no call detected reads the frontmost calling app, and with
   none open it takes no snapshots. Each snapshot
   is read with Apple's on-device text recognition and dropped at once; it is
   never written to disk or sent anywhere. With Accessibility, which
   dictation already has, it also reads the call app's window text (name
   tags, the participants list) through the Accessibility API, so names are
   read even without Screen Recording. Either way only the name-like text and its time
   are kept, in `screen-names.json` in the meeting's folder, and only the
   names are sent with the transcript for the notes. A meeting never asks
   for Screen Recording or Accessibility itself.
   A question you type in a meeting's question box is sent to Gemini with
   that meeting's notes, transcript and your earlier questions
   and answers. The questions and answers are kept in `chat.json` in the
   meeting's folder and deleted with the meeting.
5. **Your API key**, only in the request header to Google. It is stored in
   the macOS Keychain, never in files or preferences.
6. **Update checks.** Every six hours, and when you choose Check for Updates, the
   app downloads the update feed (`appcast.xml`) from the project's GitHub
   Releases (`github.com`, which redirects to GitHub's download host). The
   request carries only the app name and version and the Sparkle version in its
   User-Agent; Sparkle's system profiling is off. When an update is offered, the
   ZIP comes from the same place. GitHub sees your IP address, as with any
   download. Turn the checks off in Settings › About.

Learning from your edits never sends anything. It
re-reads the field VoiceiQ typed into, through the Accessibility API, for up to ten
minutes after an insertion, waits until you have stopped editing for a few
seconds, and adds the short replacements you made (one to three words) to the
Dictionary as words, skipping ordinary words (anything in the macOS spelling
dictionary, checked on the Mac). They ride with your audio like any other
dictionary term and are never applied as automatic text replacements.
Everything it reads stays on this Mac.

## Coding agents (only if you turn it on)

Settings › Advanced › Coding agents lets coding agents on this Mac, such as
Claude Code and Codex, read your dictations and meetings (notes, transcripts
and questions, never audio). VoiceiQ itself sends nothing anywhere for this:
it answers requests on 127.0.0.1 that carry the access key you gave the
agent. But an agent sends what it reads to its own AI provider, under that
provider's terms. It is off by default; details in
[AGENT_ACCESS.md](AGENT_ACCESS.md).

## What never leaves

- Your history database and stored recordings — audio and transcript text leave
  only as part of the requests above (or to a coding agent you allowed), never
  in bulk and never anywhere else
- Your dictionary as a file, to anyone but you. Individual terms and
  "heard as" spellings ride with the audio as described above. The
  dictionary itself (words,
  "heard as" spellings, stars, and when entries were added or deleted) is
  kept in your own iCloud account, in VoiceiQ's key-value storage, so the Mac
  and iPhone apps share it. Your custom writing rules are kept there too, for the
  same reason. The final text of each finished dictation, with
  its time, length, app name and device name, is kept in your own iCloud
  account too (VoiceiQ's private CloudKit database), so History is the same
  on both. Audio, the "as heard" transcript and errors never go to iCloud.
  Deleting a dictation in History removes it from iCloud and from the other
  device. Each finished meeting's notes, transcript, speaker names and
  questions with their answers are kept in the same private database, so
  the Mac and iPhone share them. Meeting audio never goes to iCloud.
  Deleting a meeting removes it from iCloud and from the other device.
  Nothing else VoiceiQ stores goes to iCloud
- Which apps you use, when you dictate, or anything you type
- Keystrokes: the event tap watches your dictation key, plus — only while a
  dictation is active — ⌘Esc (cancel), Space (the hands-free gesture), and the
  *fact that* another key was pressed (the accidental-chord guard; which key it
  was is never examined beyond its keycode, never logged, never stored, never
  transmitted). When you're not dictating, other keys pass through untouched.
- Screen context images and meeting name snapshots are never stored on disk and
  are never attached to meeting requests.
- Telemetry: there is none. No analytics SDK, no crash uploader, no phone-home
  beyond the update check in item 6.

## What's stored locally, and your controls

- One folder per dictation (`~/Library/Application Support/VoiceiQ/recordings/`):
  crash-safe audio, transcript, metadata — this is what makes Retry and recovery work.
- Settings → Privacy & Storage: audio retention (24h / 7d / 30d / forever / never —
  "never" disables Retry), dictation retention ("Keep dictations": never / 24h /
  7d / 30d / 1 year / forever; finished dictations older than that are
  deleted with their folders, rows waiting for Retry or your attention are
  kept), plus one-click **Delete all history**.
- Meeting audio has no retention setting: it stays until the meeting is
  deleted, so a meeting can be transcribed again. Play and Download write an
  `.m4a` copy of a recording into its own folder (`playback/`), which goes
  when the recording is deleted or its audio is removed by retention;
  Download also saves one where you choose (Downloads on the Mac).
- Logs. See [DEBUG_LOG.md](DEBUG_LOG.md). The opt-in debug log (Settings ›
  Advanced) stays on the device until you export or share it. It never holds
  API keys, tokens or text the app marks private, and keeps 7 days.
- On the iPhone, the keyboard learns how you type, as Hex's keyboard does:
  where your finger lands on each key and word-level fixes (a word you
  erased and retyped, auto-corrections you undid, suggestions you picked),
  never a keystroke log. It stays in the App Group and the keyboard's own
  container and is never sent anywhere.
- Local files are protected by FileVault if enabled; they are not separately
  encrypted (stated honestly).
- On-device models you download live in
  `~/Library/Application Support/VoiceiQ/Models` until you delete them in
  Settings. Core ML's prepared copies of them (on the Mac,
  `~/Library/Caches/io.blue.voiceiq.localspeech`) are deleted with any model,
  and at launch when no model is downloaded. See [ON_DEVICE.md](ON_DEVICE.md).
- The first launch of 0.7.12 deletes the OpenAI, ElevenLabs, TinyFish and
  agent-provider keys that earlier versions stored in the Keychain, their
  settings, and Agent mode's saved runs
  (`SettingsStore.removeRetiredSettingsOnce`). Those providers and features
  are gone; nothing is sent to them.
- On the Mac, launch cleanup (`FileLayout.removeStaleFiles`) removes any files
  left behind by the retired Chrome extension:
  `~/Library/Application Support/VoiceiQ/ChromeExtension`,
  `~/Library/Application Support/VoiceiQ/browser-speakers/`, and the
  `io.blue.voiceiq.browser.json` native messaging host manifests in
  Chromium browsers' `NativeMessagingHosts` folders. If you loaded the
  extension in a browser, remove it on that browser's Extensions page.

## Google's side of the wire

Your audio is governed by your own terms with Google: the Gemini API terms.
As of writing, paid-tier API usage is not used for model training, and
free-tier usage may be. That relationship is yours — this app doesn't broker
it. Review the [Gemini API terms](https://ai.google.dev/gemini-api/terms).

## Secure input

When a password field is focused (secure input), dictation refuses to start, and
a transcript in flight is held in History only — never inserted, never placed on
the clipboard.

## Verify it

- Build from source (`./scripts/build.sh`).
- Watch traffic with Little Snitch or `nettop` — a dictation reaches
  `generativelanguage.googleapis.com` and no other model host.
- Read the prompts: they are source files. The dictation prompt is
  [PromptV1.swift](../VoiceIQCore/Sources/FormattingPipeline/PromptV1.swift) plus
  the built-in writing rules in
  [DefaultWritingRules.swift](../VoiceIQCore/Sources/FormattingPipeline/DefaultWritingRules.swift);
  meeting transcription and summarising are in
  [GeminiClient+Meetings.swift](../VoiceIQCore/Sources/TranscriptionClient/GeminiClient+Meetings.swift).
