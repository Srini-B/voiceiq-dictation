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
2026-11-22 14:03:22.481 app notice [transcription] call transcribe (gemini-3.8-flash) id=… attempt=1 h2 ok in 812ms, first byte 640ms, sent 52311 bytes
```

A dictation also gets a `[transcription] timing:` line once its one Gemini
call ends: the FLAC encode, the dictation call that hears the audio and
writes the text, the model, the word count and the audio length. An upload
that fails before any text has none. Every dictation that reaches insertion
gets one `[session] timing` line from key-up to the result; a dictation that
fails before then has none:

```text
… app notice [transcription] timing: encode 31ms, dictation call 2604ms (gemini-3.8-flash), 41 words, 18.2s audio
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
