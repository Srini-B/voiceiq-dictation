<div align="center">

<img src="docs/images/icon.png" width="128" alt="VoiceiQ">

# VoiceiQ

**Press a key. Speak. It types.**

Smart dictation, Ask Anything, Translate, and meeting notes for macOS and iPhone, on Gemini or OpenAI with your own key.

</div>

---

## What it is

Press the dictation key, say the thing, press it again. A moment later your
words are in the app you were already using — punctuated, filler words removed,
lists laid out as lists, mid-sentence corrections applied. No window to switch
to, no transcript to copy, no account to make.

It is deliberately small: a menu bar icon, a pill at the bottom of your screen
while you talk, and a History window that proves nothing was ever lost.

## Keys

| Key | What happens |
| --- | --- |
| **Dictation key** (default `fn`) | One press starts, one press finishes. Hands-free, no holding. A bare modifier or a combination like ⌥D. |
| **`Esc`** | Cancels. Anything over 10 seconds is still kept in History. |
| **⌃⌥A** | Ask Anything. Speak a question or a command over selected text. |
| **⌃⌥T** | Translate. Speak in any language; the target language is typed. |
| **⌥M** | Start or stop meeting notes. |
| **⌘⇧V** | Paste the last transcript or answer again. |

Every key is editable in Settings → Dictation, and a shortcut can require the
left or the right modifier only. The dictation key also stops an Ask Anything or
Translate in progress.

## What makes it different

**It follows a change of mind.** Say *"let's meet at 1pm — actually, no, make it
2pm"* and VoiceiQ writes **"Let's meet at 2pm."** That is the whole pitch, and
onboarding makes you do it once so you believe it.

**It never loses your words.** Audio goes to disk from the first millisecond, so
a crash, a `kill -9`, or a flat battery costs you nothing — the recording is
recovered on next launch. Offline, dictations queue and land when you reconnect.
Every failure is retryable from History, and Retry transcribes any dictation again. Release the key mid-word and it keeps
listening until you actually stop.

**It is private by architecture.** Your voice goes from your Mac straight to the
provider you choose, Gemini or OpenAI, with *your* key. No middleman server, no
account, no analytics, no keystroke logging — one network host per dictation,
and you can read every line of the code that talks to it. Screen context (a few downscaled screenshots sent with each
dictation so on-screen names and paths are spelled right) can be switched off
in Settings → Dictation. See [PRIVACY.md](docs/PRIVACY.md).

**Your jargon, spelled right.** Names and product terms go in the Dictionary and
ride along with the audio, so the model hears "Kubernetes" instead of guessing
"cooper netties" — corrected at the source, not patched afterwards. Fix a word
after VoiceiQ types it and the correction is learned into the Dictionary on its own. The
Dictionary syncs between the Mac and iPhone through your iCloud account, and the
iPhone keyboard adds a selected or copied word in one tap.

**It writes the way you meant it.** A writing-rules pass runs on every
transcript: "scratch that", "change the first point to…" and other mid-dictation
instructions become edits, run-on speech gets sentence breaks, and your own
rules from Settings → Dictation are applied. Dictate for as long as you like;
there is no time limit.

**Ask Anything and Translate.** Select text (optional), press ⌃⌥A, and ask
("make this shorter", "what does this error mean"); the answer opens in the
pill, with Markdown rendered and a Copy button, and never edits your text. Each
question stands alone. Add a free [TinyFish](https://agent.tinyfish.ai/api-keys)
API key in Settings → Advanced and questions that need current information
(news, prices, releases) are answered from a live web search, with sources
linked. Press ⌃⌥T to dictate in any language and have it typed in
the target language you pick from the searchable list in Settings → Dictation
(99 languages); if the model cannot translate it, the pill says so and nothing
is inserted. ⌘⇧V pastes the last transcript or answer
again. All three shortcuts are editable and can require either, left, or right
modifier keys. Plain dictation is language-agnostic: speak in any language, or
mix them mid-sentence, and the text stays in the language you used.

**Stays out of your way.** Other audio is muted while you dictate and restored
after (switch it off in Settings → Dictation). Pick a preferred microphone or
leave it on system default and get a one-time notice when a new one appears.

**Meeting notes.** When Zoom, Teams, FaceTime, WhatsApp, Slack, Discord,
Webex, or a Meet/Teams/Zoom tab in any browser starts a call, the pill offers to
record it. Accept, or press ⌥M at any time, and VoiceiQ records both sides.
Press ⌥M again (or the pill's stop button) to finish: you get a
speaker-labelled transcript plus a summary, decisions, and owned action items
under Settings → Meetings. Recording never stops on its own. Meetings need a
model that labels speakers, so with OpenAI selected through a gateway they use
your OpenAI key, or Gemini when there is none. With no usable key the recording
is kept and marked failed with the reason, ready to Retry once a key is added.

**Cost Analysis.** Every model call is metered: tokens or audio seconds from the
API response, priced at the provider's list prices, or the charge a gateway
reports. Settings → Cost Analysis shows today, this week, this month, and all
time, broken down by action and by model, for Gemini or OpenAI (a toggle
switches between them); each dictation in History shows what it cost. Details in
[docs/COST_TRACKING.md](docs/COST_TRACKING.md).

## Setup

Build the app (see Development below), move `VoiceiQ.app` into
**Applications**, and launch it. Setup takes about two minutes and the app walks
you through it:

1. **Pick a provider and paste its key** — Gemini (get a key at
   [Google AI Studio](https://aistudio.google.com/apikey)) or OpenAI (get one at
   [platform.openai.com](https://platform.openai.com/api-keys)). The key is
   stored in your macOS Keychain and only ever sent to that provider. You can
   switch provider later in Settings → Advanced. If a key keeps hitting rate
   limits, the Experimental section there takes an
   [OpenRouter](https://openrouter.ai/settings/keys) or
   [Vercel AI Gateway](https://vercel.com/ai-gateway) key, which runs either
   provider's models; a gateway key entered once serves both.
2. **Allow the microphone** — say hello and it advances by itself.
3. **Allow Accessibility** — macOS requires this for any app that types into
   another app.
4. **Allow Screen Recording** (optional) — lets a few downscaled screenshots
   ride along with each dictation so on-screen names and paths are spelled right.
5. **Press the dictation key and talk.**

**Cost:** you pay the provider for what you dictate, at
[Gemini API pricing](https://ai.google.dev/pricing) (a free tier exists) or
[OpenAI API pricing](https://developers.openai.com/api/docs/pricing); a typical
dictation is a few seconds of audio. VoiceiQ itself is free and has no account.

**Models:**

| | Gemini | OpenAI |
| --- | --- | --- |
| Transcription | `gemini-3.5-transcribe` | `gpt-transcribe` |
| Writing rules, Ask Anything, Translate, meeting notes | `gemini-3.8-flash` | `gpt-6-luna` |
| Meeting speakers | `gemini-3.5-transcribe` | `gpt-4o-transcribe-diarize` |

Settings → Advanced → Transcription provider can hand the transcription stage
to another model; the provider above still writes the text and the notes. With
an ElevenLabs key, dictation and meetings can use `scribe_v2`. With an
OpenRouter or Vercel AI Gateway key, they can use MAI Transcribe 2
(`microsoft/mai-transcribe-2`), which labels the speakers and times each word
for meetings. With a Sarvam key, they can use Saaras V4 (`saaras:v4`), which
transcribes English and 22 Indian languages, detects the language by default,
and labels speakers in meetings; the same key offers Sarvam 105B
(`sarvam-105b`) as the writing model, which is the default while Saaras
transcribes until you pick one. Sarvam prices in rupees, and Cost Analysis
shows dollars or rupees. The picker appears only when one of those
keys is stored.

With Gemini, a dictation under ten minutes is one call to `gemini-3.8-flash`
with the audio attached; OpenAI's writing model takes no audio, so every
dictation there is a transcription followed by a writing-rules pass.
Settings → Advanced can pin other model names for either provider.

## How it works

```
key ─▶ capture (CAF on disk from t=0) ─▶ key ─▶ FLAC ─▶ transcribe (Gemini or OpenAI)
                    │  (live socket streams text meanwhile)     │  (chunked past 10 min)
                    ▼                                           ▼
   cursor ◀─ insert (AX → paste → clipboard) ◀─ validate ◀─ writing-rules pass
      │                                           (gemini-3.8-flash or gpt-6-luna, with screenshots)
      ▼                                                         │
   learn from edits ─▶ Dictionary                  History (SQLite) + usage ledger
```

A few decisions worth knowing about, because they are what make it feel solid:

- **The capture graph is pre-warmed while idle**, so a key press only pays
  `engine.start()` — 20-40ms instead of 75-150ms. Preparing is not recording: no
  audio flows and no mic indicator appears until you actually hold the key.
- **The mic drains one buffer past the stop**, because the audio tap only
  delivers whole ~100ms chunks and tearing down immediately threw away the tail
  of your last word.
- **Insertion is a ladder**: Accessibility API first (no clipboard involved), then
  a guarded paste that restores your clipboard, then a "copied — press ⌘V" chip.
  It never blind-pastes into an app that stole focus mid-flight.
- **A validation gate** guards the writing-rules pass, catching the classic failure where the model *answers*
  your audio instead of transcribing it, and falls back to the raw transcript.
- **The paths that can lose words are tested.** `VoiceIQCore` is a headless Swift
  package holding the state machine, hotkey grammar, audio, transcription,
  formatting, insertion and history — so the failure modes above are exercised
  without launching the app.

The full design specs — including the failure matrix the reliability work is
built from — are in [docs/design/](docs/design/).

## iPhone

VoiceiQ also ships as an iPhone app (iOS 17+) with a voice-only keyboard. Add
the VoiceiQ keyboard with Full Access, tap the mic in any app, and the text
lands where you were typing.

- **One trip to the app, once.** The first tap starts a background session and
  sends you back to the app you were in. After that the mic starts in place,
  and the session shows in the Dynamic Island until you end it.
- **Same settings as the Mac.** Gemini or OpenAI with your own key, or
  through OpenRouter or Vercel under Experimental (keys in the iOS Keychain),
  dictionary, writing rules, Ask Anything, Translate, History and Cost.
- **Meetings are a recorder.** Record in the app, stop, and the notes are
  written with the same pipeline as on the Mac. The iPhone records the room
  mic only, because iOS does not let an app capture call audio.

It is distributed through TestFlight as "VoiceiQ Dictation". Details in
[docs/IOS.md](docs/IOS.md).

## Development

Requires macOS 14+, Xcode 16+ with the iOS SDK, and
[xcodegen](https://github.com/yonaskolb/XcodeGen). The `.xcodeproj` is
generated from `project.yml`, not checked in. One project holds both apps:
`VoiceIQ` (macOS) and `VoiceIQiOS` with its `VoiceIQKeyboard` and
`VoiceIQLiveActivity` extensions. All of them build on the `VoiceIQCore`
package; the extensions link only its small `VoiceIQBridge` library.

```bash
brew install xcodegen
./scripts/test.sh           # swift test on VoiceIQCore (shared by both apps)
./scripts/build.sh          # macOS app, Debug
./scripts/build-ios.sh      # iPhone app, keyboard and Live Activity (Simulator)
open VoiceIQ.xcodeproj      # or work in Xcode
```

Debug builds sign ad-hoc, so a clean clone needs no Apple account, certificate,
or team membership. To build under your own team instead:
`./scripts/build.sh DEVELOPMENT_TEAM=XXXXXXXXXX`, or for an iPhone
`./scripts/build-ios.sh DEVICE=1 DEVELOPMENT_TEAM=XXXXXXXXXX`. Only release
builds need the team's signing material.

Code shared by both apps lives in `VoiceIQCore`. Mac-only code (event taps,
Accessibility insertion, screen capture, system audio) is wrapped in
`#if os(macOS)`, and the iPhone gets small stand-ins in files ending `+iOS`.
CI builds both apps on every pull request.

```
App/            menu bar item, HUD pill, windows, design tokens, icon + sounds
iOS/            iPhone app, voice keyboard extension, Live Activity
VoiceIQCore/        all engine logic, headless and testable
  HotkeyEngine/     CGEventTap + the pure hold/lock/cancel grammar
  AudioEngine/      crash-safe CAF capture, device changes, prewarming
  TranscriptionClient/  Gemini, OpenAI and gateway calls, live sockets, retries, FLAC
  FormattingPipeline/   cleanup prompt, validation gate, dictionary rules
  InsertionEngine/      the AX → paste → clipboard ladder
  HistoryStore/         GRDB index, recovery, retry queue, retention
  MeetingEngine/        call detection, mic + system audio taps, diarized notes
  ScreenContext/        screenshots on app switch for spelling context
  Learning/             dictionary auto-learn from your edits
  Usage/                token metering, price book, cost ledger
  Bridge/               VoiceIQBridge: keyboard ↔ app protocol, return-link table
scripts/        build, test, icon, DMG, macOS and iOS release
docs/           privacy, releasing, cost tracking, design specs, research
```

Useful while hacking:

```bash
# every surface is reachable headlessly
open "voiceiq://settings/about"      # or /dictation /privacy /advanced /meetings /cost
open "voiceiq://history"  "voiceiq://dictionary"  "voiceiq://onboarding/5"

# watch it work
log show --last 5m --info --predicate 'subsystem == "io.blue.voiceiq"'
```

Transcript text is logged as `private` and never appears in those logs.

### Releasing

| | macOS | iPhone |
| --- | --- | --- |
| Command | `./scripts/release.sh` | `./scripts/release-ios.sh` |
| Signing | Developer ID Application | Apple Distribution + three App Store profiles |
| Output | Notarized, stapled DMG and ZIP in `build/release/` | Build on TestFlight ("VoiceiQ Internal") |
| Publish | `./scripts/publish-github-release.sh`: GitHub Release with the Sparkle appcast | Automatic to the internal group |
| Credentials | `APPLE_ID`, app-specific password, team ID | asc API key (`scripts/setup-asc.sh`, once) or a signed-in Xcode |

Pushing a new `MARKETING_VERSION` (and a higher `CURRENT_PROJECT_VERSION`) in
`project.yml` to `main` runs both scripts in GitHub Actions and publishes both
apps with AI-written release notes ([docs/UPDATES.md](docs/UPDATES.md)). Both
scripts run the `VoiceIQCore` tests first and refuse to publish anything whose
signature or entitlements fail verification. The full
process, one-time setup and checks are in
[docs/RELEASING.md](docs/RELEASING.md).

## License and attribution

VoiceiQ is based on [Jot](https://github.com/google-gemini/jot-gemini-transcribe-macOS),
Copyright 2026 Google LLC, and is distributed under the Apache License 2.0
([LICENSE](LICENSE)). Changes since the fork are by Blue Lobster Technology.
Third-party components and their licenses are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). This is not an officially
supported Google product.
