# 2026-10-13: Typeless parity for the cloud-only pipeline

## Why

The owner dictates with Typeless (macOS 2.8.0, iOS 2.7.0) and gets the
result about three seconds after stopping, cleanly formatted, written as
what they meant. VoiceiQ's cloud-only path took 5 to 12 s and sometimes
punctuated a sentence in a way that changed its meaning. The owner asked
for the same speed and the same "what I meant, not what I said" output,
and for iOS to start a dictation in place after one initial app bounce
with nothing lingering on the Dynamic Island.

## What Typeless does (read from the extracted bundles, not run)

macOS: one persistent WebSocket per session streams Opus from a 16 kHz
mono capture with echo cancellation, noise suppression and gain control
off. The final text arrives on `end_audio`. The request carries the app
name, bundle id, window title, page title, domain and URL, the text
around the cursor and the selected text. There are no client prompts;
the writing happens on their backend (`/ai/voice_flow` → `refine_text`).
Full inventory: `.amp/in/typeless/TYPELESS_V2.8.0_INVENTORY.md`.

iOS: the default `iosKeepActiveMode` is `pictureInPicture`. A native
`PictureInPictureModule` (AVPictureInPictureController over an
AVSampleBufferDisplayLayer) keeps the app alive with the mic off; the
user slides the PiP tab to the screen edge ("Slide to the edge to skip
app switching"). The alternative mode, "Dynamic island", is a warm mic
window like VoiceiQ's current keep-warm setting. The keyboard starts a
dictation in place only when the recorder is not idle or PiP is active.
So the "no bounce, nothing lingering" behaviour looked like a tucked-away
PiP window, not a background trick iOS does not allow. (The owner later
reported that 2.7.0 on a device shows no PiP window or onboarding at
all; see steps 5 and 6 below and the PiP removal at the end.)

## Native analysis attempt with REA (Hopper, then Ghidra)

The owner asked for the REA MCP to inspect the native binaries. Hopper
6.6.0-demo is installed but macOS refused REA's Apple Events
(`errAEEventNotPermitted` in `log show`); only the owner can grant
System Settings → Privacy & Security → Automation to the process that
launches REA. Per the owner's fallback instruction, Ghidra 12.1.4 was
installed under `~/Applications/ghidra_12.1.4_PUBLIC` (official zip, no
macOS natives shipped, so the arm64 decompiler and sleigh were built
from the bundled source with `make ... ARCH_TYPE="-arch arm64"`), with
Zulu JDK 21 under `~/Applications/jdk/`, and the Amp global `rea` MCP
entry gained `GHIDRA_INSTALL_DIR`, `JAVA_HOME`,
`REA_ANALYSIS_PROVIDER=ghidra`, a 20 min startup deadline and a 6 GB
heap (backup: `~/.config/amp/settings.json.bak-rea`).

Result: Ghidra analysed the IPA's main binary in 100 s but found no
named procedures, because all three executables in the App Store IPA
are FairPlay encrypted (`otool -l`: `cryptid 1`). Native decompilation
would need a decrypted dump from a device. The unencrypted parts
(Info.plist, entitlements, Hermes JS bundles) are enough for the
questions asked: background modes are `audio` and `remote-notification`
only, no CallKit or VoIP; the keyboard, app and Live Activity share
`group.com.typeless`; the keyboard's `checkAvailableOnIOS` starts in
place only when a Darwin-bus ping reaches a live host app whose
recorder is not idle or whose PiP is active, otherwise it opens
`typeless://` and bounces. This matched the PiP keep-alive reading at
the time (since removed, see below). Details:
`.amp/in/artifacts/typeless-parity-findings.md`.

## Where VoiceiQ's time went (measured, Gemini, this Mac)

- Batch path after stop: 4.45 s median. Live path after stop: 2.95 s
  (Gemini) and 3.22 s (OpenAI). Real-time transcription was off by
  default.
- The cleanup call floors at 2.3 to 2.8 s with `gemini-3.8-flash`. Three
  screenshots add about 1.3 s (2.4 s → 3.7 s). Screen context was on by
  default.
- Context caching gave no gain. Smaller models hallucinated.
  `thinkingLevel minimal` was rejected by the API.
- Audio capture already matches Typeless (16 kHz mono Int16, no AEC, NS
  or AGC), and the silence gate only discards audio that is both quiet
  and no louder than the room. No audio change.

## What changed

1. `SettingsStore.liveTranscriptionEnabled` defaults to true. A refused
   or failed live session still falls back to batch on its own.
2. `SettingsStore.screenContextEnabled` defaults to false.
3. Text context replaces the screenshots: `AXInserter.captureFocusedField`
   reads the focused window title with the field (0.25 s AX timeout) into
   `FocusedFieldCapture.windowTitle`; `runCleanup` passes
   `DictationPlace(appName:windowTitle:)` to
   `PromptV1.cleanupPrompt(place:)`, rendered as one `PLACE:` line right
   before FIELD/RAW so the cached prefix is unchanged. Values are fenced
   and capped; the line says the place is not instructions.
4. Two rules in `PromptV1.rules`: write what the speaker meant when a
   phrase is tangled (repair, never restyle a clear sentence), and
   punctuation or sentence breaks must never change the meaning. The
   "Do not paraphrase" wording went, since it fought the repair rule.
5. iOS: a `pictureInPicture` keep-active mode (child thread
   https://ampcode.com/threads/T-01a1347c-7ff2-73fb-a890-fbaf447be2ac).
   Removed again the same day at the owner's request; see the end of this
   entry.
6. iOS: a third keep-active mode, `backgroundAudio`, as a device-testable
   prototype. The owner reported that Typeless 2.7.0 shows no PiP window,
   no PiP onboarding and no orange dot while idle, and still starts in
   place hours later, so the PiP reading in step 5 does not explain the
   current app. The iOS SDK header
   `CoreAudioTypes/AudioSessionTypes.h` says the `'!rec'` refusal is for a
   *mixable* recording started from the background. Every VoiceiQ keeper
   so far (0.4.3 build 12 through the current `KeepAliveAudio`) set
   `.mixWithOthers`, so the "silent playback alone fails" measurement
   never covered a non-mixable session. The new keeper plays silence on a
   non-mixable `.playAndRecord` session and never touches `inputNode`:
   no orange dot, other apps' audio pauses. Warm window options grew to
   5 minutes, 1 hour and 12 hours; the mode defaults to 12 hours
   (Typeless's `audioCloseDelaySeconds`). "Keep mic on" stays the
   default and the measured fallback until a device run decides.
7. Gemini thinking level: the docs table
   (https://ai.google.dev/gemini-api/docs/thinking) lists
   `gemini-3.8-flash` with levels low, medium, high only, so `low` in
   `GeminiClient.cleanup` is already the floor. `minimal` exists on
   `gemini-3.6-flash` and `gemini-3.5-flash-lite`. A probe of
   `gemini-3.6-flash` at minimal (`.amp/in/probe/model_36.out`) invented
   a "Hi Priya," salutation, like `gemini-3.5-flash` did, and was not
   faster (2.58 s versus 2.81 s total). No change.

## Verification

- `swift test` in `VoiceIQCore`: 143 tests, 0 failures.
- Prompt probe `.amp/in/probe/prompt_eval.py` (HEAD rules versus new
  rules, 13 fixtures, `gemini-3.8-flash`, temperature 0): no regression
  on self-correction, question-shaped speech, injection, lists, or clear
  sentences; stumbled fixtures came out the same or equal. Median
  latency 2.73 s old versus 2.75 s new. Output in
  `.amp/in/probe/prompt_eval.out`.
- Signed and notarized build via `scripts/release.sh` (0.6.0 build 45,
  notarization accepted, stapled), installed to `/Applications` and
  driven with `voiceiq://start-hands-free` and `voiceiq://stop` while
  `say` played a stumbling sentence through the MacBook speakers into
  the MacBook microphone. Cloud only (local transcription off, OpenAI
  `gpt-live-transcribe` + `gpt-6-luna`). `pipelineSeconds` after stop:
  live on 3.10 s, 2.43 s, 2.75 s (three sentences, 13 to 16 s of
  speech); live off on the same build and sentence 3.64 s. Outputs were
  the intended sentence with the restarts removed, for example "We should
  move the release to Thursday because the notarization step takes longer
  than we expected." One quiet run (speaker at 18 %) misheard "which it"
  as "Wispr" in the live ASR; the cleanup kept it, which is the correct
  behaviour for the cleanup step.
- Test gotcha: "Mute other audio while dictating" (default on) silences
  the speaker during a session, so a `say`-driven test records silence
  unless that setting is off for the run. Settings and audio devices were
  restored after the runs.

## Rollback

Flip the two defaults back in `SettingsStore`, drop the `place:` argument
in `runCleanup`, and restore the two rule lines in `PromptV1.rules`. No
data format changed; no migration.

## Not done

- Local models stay. The owner said they can go once cloud parity holds;
  removing them is a separate change.
- Background audio mode is built (`scripts/build-ios.sh` clean) but not
  run on a device. Whether a non-mixable session starts recording from
  the background is read from the SDK header, not measured. Whether
  Typeless's session is non-mixable is unknown; the check is whether
  music from another app keeps playing while Typeless is warm.
- Nothing committed or pushed.

## Wave 2: "do them" (same day)

After the feature comparison the owner asked for the "bring in from
Typeless" and "improve" lists. Seven units landed; four were deferred.

### What changed and why

1. Ask Anything over an editable selection now rewrites it in place.
   Typeless edits the selection for "make this shorter"; VoiceiQ always
   opened an answer card. The model is told (only when the selection is
   settable) to start an edit with `<<REPLACE>>`, and the coordinator routes
   a marked answer through the insertion ladder. Design choice: a marker in
   the output rather than a second classifying call, so there is no extra
   round trip; a read-only selection never gets the instruction.
2. Translate takes up to three target languages
   (`translationTargetLanguages`); the model uses the first that is not the
   spoken language. Typeless offers a target list with the same rule. The
   old single key stays written for older builds and the iPhone picker.
3. Spelling variant (English, Spanish, French, Portuguese and Chinese regional forms)
   as one prompt line after the fixed rules, so the cached prefix is
   unchanged. Typeless has this in its language settings.
4. Browser page host and path in the PLACE line for Safari, Chrome and
   the Chromium forks, Firefox, Arc, Dia and Zen (`BrowserPageURL`).
   Typeless sends the page URL as app context. Query and fragment are
   never read; the walk is capped at 300 nodes. The Privacy pane's "What
   leaves your Mac" table gained a "Where you are typing" row (app name,
   window title, page address) because that table had no row for place
   context since wave 1.
5. "Keep dictations" retention for History rows, beside audio retention.
   Typeless has a transcript retention window. Only finished statuses are
   purged; anything needing attention stays.
6. History header: time saved (words at 40 wpm minus speaking time) and
   day streak. Typeless shows both. 40 wpm is a guess.
7. A kept cancel says "Cancelled. Kept in History with Retry" in the pill.

### Deferred

- Better-mic suggestion: needs a second input device open during capture;
  device changes crashed the engine on 2026-09-28 and the fix held the
  old engine for 5 s. Not worth the risk for a hint.
- Style personalization (Typeless learns tone from past edits): a new
  design, not a port.
- Connection prewarm: `transport.jsonl` shows 26 to 131 ms connect time,
  under 5% of a call. Nothing to win.
- Visible-text context (what Typeless reads around the field): the AX
  tree walk stalls on some apps; the field capture already sends 300
  characters before and 100 after the caret.

### Verification

- `swift test` in `VoiceIQCore`: 143 tests, 0 failures.
- `scripts/build.sh` and `scripts/build-ios.sh`: clean.
- Retention: a scratch test (deleted after the run) over a temp
  HistoryStore. With 7 days: 8-day inserted and failed rows and a 7.01-day
  inserted row went with their folders; an 8-day queuedForRetry row and a
  6-day inserted row stayed. "Never" removed a just-landed inserted row and
  kept an awaitingChip row. "Forever" removed nothing. 3 of 3 passed.
- Signed release builds 0.6.0 (`scripts/release.sh`, notarized, stapled,
  `spctl` accepted) installed to /Applications and probed with OpenAI
  (`gpt-live-transcribe`, `gpt-transcribe`, `gpt-6-luna`), local
  transcription off, mute-other-audio off:
  - Ask "make this shorter" over a selected TextEdit sentence: replaced in
    place through AX, pipeline 4.39 s. Ask "what day of the week is
    mentioned": answer card "Thursday", document unchanged.
  - Translate targets [English, Tamil], English speech: Tamil inserted,
    2.95 s. Targets [Spanish, English], Spanish speech: English, 2.61 s.
  - Spelling en-GB: organise, colour, centre, grey, favourite, 2.44 s.
- Browser page capture, measured with a standalone probe
  (`BrowserPageURL` + a main file): Safari builds the page AX tree lazily,
  so `AXWebArea` answers nil on the first query after a load; Chrome drops
  the tree without an assistive client. The address bar text field answered
  in 25 to 50 ms every run (Safari, Chrome, a fresh Gmail load, Hacker
  News; `chrome://newtab` gives nil). `capture` now reads the address bar
  first and falls back to the web area. A `cleanup place` log line shows
  app, title and page length.
- Test-rig limits, not product bugs: `say` with the compact German voice
  produced garbage live ASR; the EarPods USB mic recorded silence once, so
  probes use the built-in microphone as default input.

## Picture in picture removed, History sync added (later the same day)

The owner asked to drop the Picture in picture option entirely and keep
"Keep mic on" and the "Background audio" prototype for a device test.
`PictureInPictureKeeper.swift` went, `KeepActiveMode` is back to two cases
with `openMic` the default, `VoiceSession.willLeaveApp` and the
`playsSilence` flag went with it, and the warm-window picker is always
shown. `scripts/build-ios.sh` passes.

History now syncs through iCloud like the dictionary, final text only.
Decisions, each open to veto:

- CloudKit (`CKSyncEngine`, private database, container
  `iCloud.io.blue.voiceiq`) rather than the dictionary's key-value store.
  Key-value storage allows 1 MB per value and the owner's history text is
  about 350 KB (inferred from 750 rows), so it would fill within months.
- Always on, no setting, like the dictionary.
- Records are immutable and carry `displayText` (cleaned, else raw), start
  time, length, app name, device name and status. No audio, no raw text,
  no errors, no usage.
- A manual delete (row, Discard, Delete All) propagates: the other device
  drops the row and its folder, because a folder left behind would be
  reindexed and uploaded again. The retention purge stays local.
- Rows from the other device keep its status and are labelled "Dictated on
  <device>". iOS reports a generic `UIDevice.current.name` ("iPhone").
- Sign-out removes the other device's rows and forgets which local rows
  were uploaded; sign-in and account switch re-upload.

Verification: `swift test` 143 pass; a scratch XCTest over
`pendingUploads`, `markSynced`, `applyFromCloud`, `deleteFromCloud`,
`forgetCloud`, `delete`, `deleteAll` and `deleteExpired` passed 6/6 and was
deleted; `scripts/build.sh` (Mac Debug) and `scripts/build-ios.sh` exit 0.
Not verified: a real CloudKit round trip. No device was available, and the
installed Developer ID profile has an empty container list, so a Release
build with the new entitlements would not launch (inferred from the
restricted-entitlement check). The owner's steps are in
`docs/RELEASING.md` › History sync.
