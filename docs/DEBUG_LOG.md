# Logs and the debug log

## Logs the apps keep without asking

| Log | Platform | Where | How much is kept | When old entries go |
| --- | --- | --- | --- | --- |
| Session log (`SessionDiagnostics`) | iOS | `Caches/session-log.txt` in the app container | The newest 400 lines | Each new line past 400 drops the oldest. No age limit. **Clear** in Settings › Advanced › Session log deletes it. iOS may also empty Caches when storage runs low. |
| Keyboard log (`SharedStore.keyboardLog`) | iOS | App Group defaults | The newest 100 lines | Each new line past 100 drops the oldest. No age limit. The same **Clear** deletes it. |
| Request log (`TransportLog`) | iOS and Mac | `Application Support/VoiceiQ/transport.jsonl` | Up to 2 MB, plus the previous 2 MB in `transport.1.jsonl` | When the file passes 2 MB it replaces `transport.1.jsonl`. No age limit and no button. |
| Unified log (`Log`, `os.Logger`) | iOS and Mac | The system log | Set by the OS | `info` and `debug` messages are kept in memory only. `notice`, `error` and `fault` messages are kept on disk until the OS rotates them by size, usually a few days. Read them with Console or a sysdiagnose. |

None of these hold API keys or transcript text. Dictation history is separate:
audio is kept 7 days by default and transcripts until deleted (Settings ›
Privacy).

## The debug log

Settings › Advanced › **Write a debug log**, on the Mac and on iOS. Off by
default.

While it is on, every message the app logs through `Log` (dictation,
transcription, meetings, insertion,
history sync, dictionary and writing-rule sync, usage, permissions, errors,
and the timing line of every model request) is also written to a file. So
are:

- every settings change (`SettingsStore.set`, and iOS's microphone and
  warm-window choices), as the key and a short value. Text over 80
  characters, lists and data are logged by size only;
- the iOS keyboard's decisions (`KeyboardLog`);
- one line per process launch with the version, build, OS and device model.

New code is covered by logging through `Log` as before; nothing else is needed.

### Where it is

| Platform | Folder |
| --- | --- |
| Mac | `~/Library/Logs/VoiceiQ/` |
| iOS | `Library/Logs/VoiceiQ/` in the App Group container (the app and the keyboard) |

Each process writes its own file per day, such as
`debug-2026-11-12-app.log` and `debug-2026-11-12-keyboard.log`. Two processes never write the same file. A line looks like:

```text
2026-11-22 14:03:22.481 app notice [transcription] call cleanup (gpt-6-luna) id=… attempt=1 h2 ok in 812ms, first byte 640ms, sent 5231 bytes
```

A dictation also gets two `[transcription] timing:` lines: one when its
transcript is ready (from key-up, with the speech model: STT-3.7 Realtime
when the stream held, pre-recorded STT-3.7 or Universal-2 when it did not)
and one when the writing model has written the text. A dictation that fails
before any text has none. Every dictation that reaches insertion
gets one `[session] timing` line from key-up to the result; a dictation that
fails before then has none:

```text
… app notice [transcription] timing: transcript 180ms (assemblyai-stt-3-7-realtime), 18.2s audio
… app notice [transcription] timing: key-up to text 2620ms
… app notice [session] timing 26A1A1D4-…: finalize 233ms, upload 2638ms, insert 133ms, key-up to done 3004ms
```

`finalize` is key-up to the recording being closed. Recording stops at
key-up, even mid-word (there is no listening past it since 2026-11-20); what
remains is waiting until the audio captured up to key-up has been written
(`tail drained`; buffers arrive every ~10 ms at 512 frames and 48 kHz, after
the input's own latency, capped at 160 ms), then stopping the engine and
closing the file.

A `mic audio skipped Nms … filled with silence` line means the input dropped
50 to 250 ms of audio, which a Bluetooth microphone often does as it starts;
the recording gets that much silence so the words on either side stay apart.
A longer dropout is logged as `too long to fill` and left as it is.

`upload` covers encoding and the dictation call. Each request attempt inside
it has its own `call` line, so one interval can hold several: a second
attempt of the same request on a fresh connection, or one chunk per request
for a dictation over ten minutes. History shows the same steps under
**Pipeline** on the Mac and iPhone (`SessionMeta.steps`,
`DictationSteps.rows`). Dictations from before 0.7.12, which transcribed and
then ran a separate writing pass, also show a Writing model step.

### Keeping and deleting

`DebugLog.keepDays` (7) and `DebugLog.maxTotalBytes` (30 MB). Day files older
than 7 days are deleted at launch, every 6 hours on the Mac
(`RetentionPolicy.purge`), on each process's first line of a day, and after
every 1 MB a process writes. When
all files pass 30 MB, the oldest days go first. Turning the log off keeps the
files until they age out or the user taps **Clear**.

### Export

- Mac: **Export…** saves one text file, **Show in Finder** opens the folder.
- iOS: Settings › Advanced › Debug log shows the newest 500 lines; the share
  button sends the whole log as one file.

The export merges every process's lines in time order under a header with the
version, OS and device (`DebugLog.export`), in a folder of its own in the
temporary folder; `DebugLog.discardExport` removes it once saved or shared,
and Clear removes every export.

### What is never written

- `privacy: .private` values are written as `<private>` (transcripts, window
  titles, page addresses, server error text).
- Every line passes `DebugLog.redact` before it is written. It removes each
  key `KeychainStore` has loaded or saved, whatever its format, and anything
  shaped like a provider key (`AIza…`, `sk-…`, `sk_…`), a bearer or basic
  token, a JWT, or the value of a `key=`, `token:`, `api_key=`,
  `authorization:` or similar pair.

### How `Log` feeds it

`Log.<category>` is a `LogChannel`, which takes the same calls as `Logger`
(`debug`, `info`, `notice`, `warning`, `error`, `fault`) and the same
interpolations (`privacy:` and `format: .fixed(precision:)`). Each message
goes to the unified log with the same privacy as before (`.auto` shows
numbers and Bools and hides the rest) and to `DebugLog.write`. In the debug
log, `.auto` values are shown after redaction, because they are mostly errors
and counts.

## Dictating from audio files (end-to-end tests)

On a Mac without a usable microphone (a remote test machine), the app can take
its dictation audio from files instead:

```sh
defaults write io.blue.voiceiq DebugDictationAudioFiles -array /path/one.wav /path/two.wav
# restart VoiceiQ; each dictation plays the next file, in turn
defaults delete io.blue.voiceiq DebugDictationAudioFiles
```

Each dictation (`FileAudioCapture`) plays the next listed file in real time,
converted to the recorder's 16 kHz mono format, so the realtime transcript,
the waveform and the silence check see it as speech; after the file ends it
records silence until the dictation is stopped. A file that can't be read
falls back to the microphone. The log has `debug audio: dictation from …` for
each one. Nothing changes while the default is unset.

Keep the files outside ~/Documents, ~/Desktop and ~/Downloads, for example in
/Users/Shared. The files are opened on the main thread, and opening one in a
privacy-protected folder can wait on a permission prompt and hang the app at
"warming".

## Test mode

Two defaults keep what a test records out of the owner's iCloud and the real
app's data. On a shared test Mac, set them on the installed signed app for the
run: a re-signed copy can't be granted Screen Recording and Accessibility
without the admin password.

```sh
# with VoiceiQ quit; the Dictionary and other settings live in the defaults
# domain, not the data folder, so save them and put them back afterwards
defaults export io.blue.voiceiq /Users/Shared/voiceiq-pre-test.plist
# Markdown export ignores test mode and may write into iCloud Drive
defaults delete io.blue.voiceiq meetingMarkdownFolder 2>/dev/null || true
defaults write io.blue.voiceiq DebugDisableCloudSync -bool true
defaults write io.blue.voiceiq DebugDataFolder /Users/Shared/voiceiq-probe-data
# launch it; its menu shows "Sync off (test)" and "Data in … (test)"
# afterwards: quit it, then
# import alone merges, so clear the domain first; this also drops both keys
test -s /Users/Shared/voiceiq-pre-test.plist && defaults delete io.blue.voiceiq &&
  defaults import io.blue.voiceiq /Users/Shared/voiceiq-pre-test.plist
# relaunch it and check neither "(test)" line is left
```

| Default | What it does | Platforms |
| --- | --- | --- |
| `DebugDisableCloudSync` | None of the five syncs starts: meetings and History (CloudKit), the Dictionary, writing rules and meeting folders (iCloud key-value storage). | Mac, iPhone |
| `DebugDataFolder` | An absolute path that replaces ~/Library/Application Support/VoiceiQ for everything the app stores. Keys go to the Keychain under the service `io.blue.voiceiq.test` instead of `io.blue.voiceiq`, so the run starts with no AssemblyAI or agent access key and never changes the real ones; enter a key in Settings for a run that needs one. | Mac |

Both are read once, at launch, from the app's own defaults domain, so
`defaults delete <domain>` turns them off too. Check the menu lines after a
reset. Each is logged (`iCloud sync off: DebugDisableCloudSync is set`,
`data folder (test): <path>`) and shown on screen: in the Mac menu under the
status line, and "Sync off (test)" under the version in the iPhone's
Settings. There is no user-facing switch. A `DebugDataFolder` that is not an
absolute path is ignored and logged as an error.

Why both: VoiceiQ is not sandboxed, so a copy under another bundle ID, such as
the live-call probe's ~/Applications/VoiceiQ-probe.app (io.blue.voiceiq.probe,
ad hoc signed without the iCloud entitlement), still writes into the real
folder by default. The real app then uploads those meetings at its next
launch. The data folder is never derived from the bundle ID: on iOS the app,
its keyboard and its Live Activity share an App Group under different IDs.

### What the sync switch does not cover

It defers sync; it does not isolate the run. Changes made while it is set stay
on the device and go up once sync is back on: new and edited dictations and
meetings, Dictionary terms (auto-learned ones too), writing rules and folders.
So on the real app, delete a test's dictations and meetings before deleting the
default. Two things never catch up:
- A dictation that was already in iCloud and is deleted (or cleared with
  Clear all) while the switch is on stays in iCloud and on other devices.
  Delete already-synced dictations with sync on.
- Meetings written as Markdown files (Settings, off by default) still go to
  the chosen folder, which may be in iCloud Drive.

### What a test copy still shares with the real app

- The debug log in ~/Library/Logs/VoiceiQ, and its on/off switch, which a copy
  reads from the real app's defaults domain.
- The Keychain, apart from VoiceiQ's own keys (`io.blue.voiceiq.test` in test mode).
- The temporary folder: each app's launch cleanup removes the other's
  in-progress playback renders.
- The prepared-model cache. With `DebugDataFolder` set the copy does not clear
  it at launch, and it does not start the agent server or touch the user's
  agent configs (~/.claude.json and the others). Its Settings still act on the
  shared state when clicked: the Coding agents buttons (Set Up, Update,
  Remove, New Key…) change the real agent configs, writing the test key into
  them, and
  deleting a model clears the shared cache. Leave them alone in a test copy.

Start the data folder empty, or copy the whole real folder. Never copy
history.sqlite alone: its rows hold absolute paths to recordings, and a delete,
a retry or retention in the copy would then change the real files. The example
path in /Users/Shared is readable by other accounts on the Mac.
