# Privacy

## The promise

By default, your voice goes from your Mac directly to the model provider you chose in
Settings → Advanced, using your own API key: Google's Gemini API or OpenAI's API.
Optional Fluid Speech Mini or Nemotron transcription processes audio on-device on supported systems
(Fluid Speech Mini only on iPhone and iPad).
Cleanup and screen context still use your selected cloud provider. Failed local
transcription falls back to sending the saved audio to that provider.
If you add an ElevenLabs key and set the Transcription or Meeting
transcription picker to ElevenLabs, that audio goes to ElevenLabs
(`api.elevenlabs.io`) with your ElevenLabs key instead, and only the transcript
goes on to the provider for the writing rules and meeting notes.
There is no VoiceiQ server, no account, no analytics, no telemetry.
Everything else stays on your Mac. The code is open — verify all of this.

"The provider" below means the one you selected:
`generativelanguage.googleapis.com` (Gemini) or `api.openai.com` (OpenAI).
Only it receives a given dictation; nothing is sent to the other. Meetings are
the one exception: a meeting goes to the selected provider when its key is
saved, otherwise to the other provider, and a meeting whose provider fails
moves on to the other provider you have a key for. With ElevenLabs as the
meeting transcription source, meeting audio goes only there and the provider
receives the transcript for the notes.
With no usable key, nothing is sent and the recording stays on your Mac.

## What leaves your machine (the complete list)

1. **The audio of each cloud dictation**, sent to the provider. With "Real-time
   transcription" off, VoiceiQ sends FLAC-compressed audio after you stop.
   With it on, VoiceiQ sends PCM audio while you speak in Dictation, Ask
   Anything, Translate and Agent. It uses the selected provider's existing
   key. If the live connection fails or does not return every completed turn,
   VoiceiQ uploads the saved recording to that provider after you stop.
   Real-time transcription is on by default (since 2026-10-13, so the result
   lands about 1.5 s sooner after you stop) and does not affect meetings.
   With "On-device transcription" on and the selected model downloaded,
   successful transcription sends no audio. The explicit Download button fetches
   252.7 MB for Fluid Speech Mini or 664.8 MB for Nemotron from Hugging Face and its CDN, exposing your IP address
   to those hosts, but sending no recordings or API keys. Missing models use the
   configured cloud transcription. Failed local results upload the saved
   recording through the existing cloud path. This option is not an offline-only
   privacy mode. See [local transcription](LOCAL_TRANSCRIPTION.md).
   With ElevenLabs as the transcription source, this audio goes to ElevenLabs
   instead, as FLAC after you stop (ElevenLabs has no live socket), along with
   up to 100 dictionary terms as `keyterms`, and the provider never receives
   it: the writing-rules request (item 3) carries no audio in that case.
   Removing the ElevenLabs key sends later dictations to the provider again.
2. **Your dictionary terms**, alongside that audio. The transcription model uses
   them to bias what it hears, which is why names and jargon come out spelled
   right as you speak rather than being corrected afterwards. Only the correct
   spellings are sent — never the misspellings you record. They ride on every
   dictation, including with Smart transcription off.
3. **The writing-rules prompt**, while "Apply writing rules" is on in
   Settings → Dictation — on by default. "Skip cleanup for dictations of 5 seconds
   or less" is also on by default. With that setting on, short ordinary dictations
   skip this request and insert the transcript with local dictionary rules.
   Turn it off to send short dictations for cleanup too. Longer dictations run
   cleanup after transcription. The request
   sends text only (and screen images, item 4), never the audio. It contains the transcript being
   formatted, the built-in formatting rules, your custom instructions from the
   same pane, the frontmost app's name and the title of its focused window
   (a document name, a page title, a chat name; since 2026-10-13), in Safari,
   Chrome, Edge, Brave, Vivaldi, Arc, Dia, Opera, Firefox and Zen the host and
   path of the page in that window (never the query string or fragment, so no
   search terms or tokens; also since 2026-10-13), your spelling choice from
   the same pane, your
   dictionary terms, and, while
   "Fit to existing text" is on (on by default), up to 300 characters before
   the cursor and 100 after it in the field you are dictating into. No tone or
   category is derived from the app; the model reads intent from your speech
   and uses the app and window names only to tell what kind of text this is
   and how names on screen are spelled. With that
   setting off, a dictation's transcript never leaves this Mac after
   transcription. Ask Anything and Translate always send it (item 7).
4. **Screen context**, while "Screen context" is on in Settings → Dictation — off
   by default since 2026-10-13 (three images added about 1.3 s to every
   cleanup; the app and window names in item 3 replace them). VoiceiQ captures the main display when dictation starts and when
   the frontmost app changes during that dictation. It sends up to four reduced-
   size JPEG images to the provider only with the writing-rules request. VoiceiQ keeps
   the images in memory and never stores them on disk. macOS asks for Screen
   Recording permission the first time this feature runs. If you deny access,
   dictation continues without images. Turn off "Screen context" to stop capture.
5. **Ask Anything web search**, only if you saved a TinyFish API key in
   Settings → Advanced (off by default; there is no key until you add one).
   For each Ask Anything request the provider's model first decides whether
   the question needs current information. If it does, VoiceiQ sends one short search
   query to `api.search.tinyfish.ai` and fetches the top three result pages
   through `api.fetch.tinyfish.ai`. Your spoken instruction and any selected
   text go only to the provider; TinyFish receives the search query and the
   page URLs. The fetched page text is placed in the provider prompt and
   discarded.
   Remove the key to stop this entirely.
6. **Meeting audio**, only after you start a recording. With "Offer to record
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
   recording, mic and system audio are written to
   `~/Library/Application Support/VoiceiQ/meetings/` and nothing is sent.
   Recording stops only when you stop it; the stretches with speech are then
   sent to the provider for a speaker-labelled transcript, and that
   transcript is sent back for a summary and action items. With "Meeting
   transcription" on device and the models downloaded (Fluid Speech Mini and
   Nemotron 3 Diarization on the Mac; Fluid Speech Mini alone on iPhone and
   iPad, where the transcript has one speaker), the audio never leaves the
   device: the words and speakers are worked out locally, and only the
   transcript is sent, for the notes. If that on-device pass fails and a key is saved, the audio is sent
   as above. Turn the setting off and no call detection runs.
   With "Read names from the screen" on (Settings → Dictation, on by default,
   macOS only) and Screen Recording already granted, VoiceiQ takes a snapshot
   of the call window every 3 seconds while recording (the main display,
   minus VoiceiQ's own windows, when no call app was detected). Each snapshot
   is read with Apple's on-device text recognition and dropped at once; it is
   never written to disk or sent anywhere. Only the name-like text and its time
   are kept, in `screen-names.json` in the meeting's folder, and only the names
   are sent with the transcript for the notes. With Accessibility granted, it
   also reads the call app's window text (name tags, the participants list)
   through the Accessibility API, with the same rule: only name-like text is
   kept. A meeting never asks for Screen Recording or Accessibility itself.
7. **The selected text, when you use Ask Anything** (⌃⌥A by default). At the
   moment you press the shortcut, VoiceiQ reads the text selected in the
   frontmost app through the Accessibility API and sends it with your spoken
   instruction to the provider. Nothing else in the window is read. Translate (⌃⌥T)
   sends only your dictation, as a normal dictation does.
8. **Your API keys**, each only in the request header to its own service: the
   Gemini key to Google, the OpenAI key to OpenAI, the ElevenLabs key to
   ElevenLabs. They are stored in the macOS Keychain, never in files or
   preferences.
9. **Update checks.** Every six hours, and when you choose Check for Updates, the
   app downloads the update feed (`appcast.xml`) from the project's GitHub
   Releases (`github.com`, which redirects to GitHub's download host). The
   request carries only the app name and version and the Sparkle version in its
   User-Agent; Sparkle's system profiling is off. When an update is offered, the
   ZIP comes from the same place. GitHub sees your IP address, as with any
   download. Turn the checks off in Settings › About.
The auto-learn feature ("Learn from your edits") never sends anything. It
re-reads the field VoiceiQ typed into, through the Accessibility API, for up to ten
minutes after an insertion, waits until you have stopped editing for a few
seconds, and adds the short replacements you made (one to three words) to the
Dictionary as words, skipping ordinary words (anything in the macOS spelling
dictionary, checked on the Mac). They ride with your audio like any other
dictionary term and are never applied as automatic text replacements.
Everything it reads stays on this Mac.

## What never leaves

- Your history database and stored recordings — audio and transcript text leave
  only as part of the requests above, never in bulk and never anywhere else
- Your dictionary as a file, to anyone but you. Individual terms ride with the
  audio as described above, and your misspelling rules are included in the
  writing-rules prompt while that pass is on. The dictionary itself (words,
  "heard as" spellings, stars, and when entries were added or deleted) is
  kept in your own iCloud account, in VoiceiQ's key-value storage, so the Mac
  and iPhone apps share it. Your custom writing rules are kept there too, for the
  same reason. The final text of each finished dictation, with
  its time, length, app name and device name, is kept in your own iCloud
  account too (VoiceiQ's private CloudKit database), so History is the same
  on both. Audio, the "as heard" transcript and errors never go to iCloud.
  Deleting a dictation in History removes it from iCloud and from the other
  device. Nothing else VoiceiQ stores goes to iCloud
- Which apps you use, when you dictate, or anything you type
- Keystrokes: the event tap watches your dictation key, plus — only while a
  dictation is active — Esc (cancel), Space (the hands-free gesture), and the
  *fact that* another key was pressed (the accidental-chord guard; which key it
  was is never examined beyond its keycode, never logged, never stored, never
  transmitted). When you're not dictating, other keys pass through untouched.
- Screen context images and meeting name snapshots are never stored on disk and
  are never attached to Ask Anything, Translate, meeting, or transcription
  requests.
- Telemetry: there is none. No analytics SDK, no crash uploader, no phone-home
  beyond the update check in item 9.

## What's stored locally, and your controls

- One folder per dictation (`~/Library/Application Support/VoiceiQ/recordings/`):
  crash-safe audio, transcript, metadata — this is what makes Retry and recovery work.
- Settings → Privacy & Storage: audio retention (24h / 7d / 30d / forever / never —
  "never" disables Retry), dictation retention ("Keep dictations": never / 24h /
  7d / 30d / 1 year / forever; finished dictations older than that are
  deleted with their folders, rows waiting for Retry or your attention are
  kept), plus one-click **Delete all history**.
- Local files are protected by FileVault if enabled; they are not separately
  encrypted (stated honestly).

## The provider's side of the wire

Your audio is governed by your own terms with whoever receives it. With Gemini,
that is the Gemini API terms with Google; as of writing, paid-tier API usage is
not used for model training, and free-tier usage may be. With OpenAI, it is
OpenAI's API terms. That relationship is yours — this app doesn't broker it. Review the
[Gemini API terms](https://ai.google.dev/gemini-api/terms) and the
[OpenAI API data controls](https://platform.openai.com/docs/guides/your-data).

## Secure input

When a password field is focused (secure input), dictation refuses to start, and
a transcript in flight is held in History only — never inserted, never placed on
the clipboard.

## Verify it

- Build from source (`./scripts/build.sh`).
- Watch traffic with Little Snitch or `nettop` — a dictation reaches the
  transcription host the active route names, and no other model host, except
  that with ElevenLabs as the source the audio goes to `api.elevenlabs.io`
  and the transcript then goes to the selected provider for the writing pass:
  two hosts (two TinyFish hosts appear only after you add a TinyFish key).
- Read the prompts: they are source files. The writing-rules pass is
  [PromptV1.swift](../VoiceIQCore/Sources/FormattingPipeline/PromptV1.swift) plus
  the default custom instructions in
  [DictationRulesSeed.swift](../VoiceIQCore/Sources/FormattingPipeline/DictationRulesSeed.swift);
  meeting transcription and summarising are in
  [GeminiClient+Meetings.swift](../VoiceIQCore/Sources/TranscriptionClient/GeminiClient+Meetings.swift),
  and OpenAI's requests in
  [GeminiClient+OpenAI.swift](../VoiceIQCore/Sources/TranscriptionClient/GeminiClient+OpenAI.swift).
