# On-device speech

VoiceiQ can transcribe dictations and meetings on the Mac, iPhone or iPad
instead of sending audio to Gemini. Gemini stays the default. The models are
Fluid Speech Pro and Fluid Speech Mini by FluidVoice (Parakeet TDT models
converted to Core ML), run through the FluidAudio package, plus pyannote
community-1 to tell meeting speakers apart. With writing Off, no model
service sees the words of an on-device dictation or meeting. Finished text still syncs to your own iCloud like any
dictation.

## Settings

Settings → Dictation → Speech has three choices, each saved on its own:

| Row | Values | Key | Default |
| --- | --- | --- | --- |
| Dictation | Gemini, On device | `transcriptionSource` | Gemini |
| Meetings | Gemini, On device | `meetingTranscriptionSource` | Gemini |
| Writing rules and notes | Gemini, Off | `cleanupSource` | Gemini |

The third row shows only when dictation or meetings run on device. It decides
who writes an on-device transcript:

- **Gemini**: the transcript goes to Gemini as text, never as audio, with the
  built-in writing rules, your custom rules, dictionary and regional spelling
  (`PromptV1.transcriptSection`). Meetings get notes. If Gemini fails or there
  is no key, the dictation goes in as transcribed.
- **Off**: no writing step for an on-device transcript; it never goes to
  Gemini as text. Dictations go in as transcribed, with the Dictionary's
  replacements. Meetings keep their transcript with speaker labels and a short
  note that no summary was written. A recording the on-device models could not
  transcribe still goes to Gemini (see below). As with every dictation and meeting, the finished text syncs to
  your own iCloud when History sync is on (see PRIVACY.md).

These choices cover what was transcribed on device. A row set to Gemini still
sends its audio to Gemini: with Meetings On device and Dictation Gemini,
dictations go to Gemini whatever this row says. A Gemini transcription always
applies the writing rules in the same request, so "Gemini transcribes,
the device writes" does not exist.

Whatever this row says, Off included, an on-device dictation or meeting whose
model is missing, busy, fails or loads too slowly goes to Gemini as audio when
a key is stored, and Gemini transcribes and writes it as with the Gemini
source. Without a key the dictation fails and stays in History for Retry, and
the meeting is marked failed.
Screen context, when on, sends its screenshots with the Gemini writing
request as it does with a Gemini dictation.

Below the three choices, the models are grouped by their job, each group
under its own header (`SpeechSourceSection`, the same on Mac, iPhone and
iPad):

| Group | Rows | Shown while |
| --- | --- | --- |
| On-device transcription | Fluid Speech Mini and Pro (the checked one is used, with its Language picker while Dictation is On device), Speaker Separation | Dictation or Meetings is On device; Speaker Separation only for Meetings |
| Add-on for English dictation | English tools | Dictation is On device |

A group whose choice is not On device still shows while one of its models is
on disk or downloading, with a note that it is not used, so the model can be
deleted or the download cancelled.

**Languages.** A Gemini dictation has no language setting: Gemini works out
the language, or several languages and each switch between them, by itself,
and the writing rules keep each language in its own script. With Dictation On
device, the transcription group's Language picker applies, and neither the
Gemini writing step nor a Gemini fallback is told a language. Meetings never
get one either: Gemini and the on-device models work out each language in a
meeting by themselves.

## Models

| Model | Size | Languages | Offered on |
| --- | --- | --- | --- |
| Fluid Speech Pro (8-bit Core ML, `FluidVoice-Labs/fluid-speech-pro-coreml@3b9d38a`) | 652.3 MB | 25 European languages | Mac; iPhone/iPad with 6 GB of RAM or more |
| Fluid Speech Mini (`d81c316`) | 252.7 MB | English | Mac; iPhone/iPad with less than 6 GB |
| English tools (Silero VAD, Parakeet CTC vocabulary) | 103.9 MB | English | optional, adds dictionary correction |
| Speaker separation (pyannote community-1) | 21.6 MB | any | needed for on-device meetings |

`LocalSpeechModel.available` gives the Mac both models. iOS offers one:
`suggested(physicalMemory:)` picks Pro at 5 GiB of `physicalMemory` or more.
iOS reports a "6 GB" device as about 5.5 GiB, so the line sits below it.

Each manifest pins a Hugging Face revision and every file's size and SHA-256.
`LocalModelInstaller` downloads into a staging folder, checks each file, then
renames the folder into `Application Support/VoiceiQ/Models/<name>/<revision>`.
The model rows show download progress, the size on disk once ready, and a
delete button.

On an iPhone on cellular data (an `NWPath` that uses the cellular interface or
is expensive, such as a personal hotspot), Download or Retry first asks
"Download on cellular data?" with the model's size from its manifest. Download
starts it; Cancel starts nothing. It asks once per download: a download that
has started, on Wi-Fi or after the user confirmed, never asks again, even if
the network drops and comes back or moves from Wi-Fi to cellular, and a Retry
after a failure carries the same consent. Once the model is downloaded or its
download is cancelled, the next download asks again. On Wi-Fi there is no
alert. A tap before the network monitor has reported its first path asks, as on
cellular. A tap with no network starts nothing and shows "No internet
connection", because the downloader retries a lost connection by itself and
could otherwise come back on cellular unasked. Downloads are never held for Wi-Fi and there is no setting; the
decision is `CellularDownloadConsent`, held by `CellularModelDownloads` in
memory only. Hex holds its downloads for Wi-Fi behind a "Use mobile data"
button (`9e41970e`, MIT); VoiceiQ asks instead. The Mac never asks.

On a model's first load Core ML writes a prepared copy of it for this device
into the loading process's caches, `com.apple.e5rt.e5bundlecache/<OS build>/`.
Copies of the speech models can reach about 1 GB. On the Mac the models load in the
`VoiceiQLocalSpeech` helper, so the copies sit in `~/Library/Caches/io.blue.voiceiq.localspeech`; on iOS they sit
in the app's `Library/Caches/<bundle id>/com.apple.e5rt.e5bundlecache`. The
cache has no per-model index, so deleting any model removes all of it
(`LocalModelInstaller.removeAll`) and the models still downloaded are prepared
again on their next load. Each launch with no model downloaded removes it too
(`FileLayout.removeStaleFiles`), which clears what 0.7.13 and earlier left
after a delete, and deletes the retired on-device writer's folder
(`Models/lfm3-omni-2b`, 1.1 GB) that 0.7.15 and earlier downloaded.

## Dictation flow

1. `DictationCoordinator` asks `localFactory` for a `LocalTranscriber` when
   the recording starts. The model loads while you speak.
2. At stop, `LocalTranscriber.finish` decodes the saved CAF.
3. The coordinator passes the result to `TranscriptionServicing.write`
   (Gemini writing, or the Dictionary's replacements when Off).
4. If the model is still loading `TimeoutPolicy.localColdLoad` after the
   recording and a Gemini key exists, the dictation goes to Gemini and the
   load finishes as a warm-up.

Two fixes from Hex (MIT) apply to the on-device transcript:

- **Numbers as digits** (English, Fluid Speech Mini and Pro, Mac and iPhone).
  The model's `EnglishText` writes numbers with `SpokenNumbers`, for every
  dictation: the text inserted with writing Off and the transcript the
  Gemini writing step receives. "Ten to fifteen percent" → "10 to
  15%", "five dollars" → "$5", while "No one came", "I work nine to five" and
  "four ninety nine" stay as said. Text that already has digits keeps them.
  It replaced FluidAudio's NeMo inverse normalization, which got 32 of Hex's
  110 number cases right ("Ten to fifteen percent" → "14:50 %"), so the
  `NemoTextProcessing` trait is no longer linked.
- **Sound-alike spellings.** After the Dictionary's replacement rules,
  `SoundAlikeSpelling` gives a capitalised name that sounds like a Dictionary
  term, and is spelled nearly the same, the term's spelling: "Stacy" →
  "Stacey"; mid-sentence only, a name that just sounds the same and is at
  most two letters off, as in "Let's invite Jeff" → "Let's invite Geoff"
  ("Jeff fixed it" stays). English only. It runs on the text inserted as
  transcribed (writing Off, no key, or Gemini failing).

History's Retry and launch recovery use `OnDeviceFirstTranscription`: the
saved recording goes to the on-device model first, then Gemini when a key is
stored. With no key nothing is sent (`GeminiClient` refuses to send).
`DictationRoute.isAvailable` (a key, or the selected model downloaded) decides
whether VoiceiQ asks for an API key, so fully offline use needs no key.

On the Mac the model runs in the `VoiceiQLocalSpeech` helper process
(`LocalSpeechHelper`). On iOS it runs in the app (`LocalSpeechInference`), and
`ModelWarmer` prepares the Core ML cache in a background task after an OS
update.

## Meetings

With Meetings set to On device, `MeetingEngine.transcribe` sends the saved
tracks to `LocalMeetingTranscriber`: speech stretches are transcribed with the
selected model and labelled by speaker with pyannote. Nothing is shown while
recording, and the work runs after you stop. If it fails and a key exists,
the meeting falls back to Gemini. With Writing rules and notes set to Gemini
and a key stored, Gemini writes the notes from the transcript; with Off, the
meeting keeps its transcript and no notes.

## Measured (cloud Mac, M4 Pro VM, 2026-11-22)

Speech models:

- Download: Mini 252.7 MB in 4 s, Pro 652.3 MB in 6 s, speaker model 1 s.
- Decode: median 0.25 s per dictation for both models. The first cold load
  took 1.2 s for Pro and 1.9 s for Mini. In the iOS Simulator, Pro loaded in
  2.3 s and decoded a 9.7 s dictation in 1.55 s on the CPU.
- Word error rate on 10 LibriSpeech clips (254 words): Pro, Mini and Gemini
  each 2.76%; on-device plus Gemini writing 1.97%.
- On-device plus Gemini writing took a median 1.9–2.0 s, against 2.7 s for
  Gemini from audio.
- Without a writing step, the text keeps "um" and "uh" and does not collapse
  self-corrections.
