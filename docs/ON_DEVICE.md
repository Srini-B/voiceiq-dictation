# On-device speech

VoiceiQ can transcribe dictations and meetings on the Mac, iPhone or iPad
instead of sending audio to Gemini. Gemini stays the default. The models are
Fluid Speech Pro and Fluid Speech Mini by FluidVoice (Parakeet TDT models
converted to Core ML), run through the FluidAudio package, plus pyannote
community-1 to tell meeting speakers apart.

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
- **Off**: nothing leaves the device. Dictations go in as transcribed, with
  the Dictionary's replacements. Meetings keep their transcript with speaker
  labels and a short note that no summary was written.

A Gemini transcription always applies the writing rules in the same request,
so "Gemini transcribes, on-device writes" does not exist. See
[Offline cleanup](#offline-cleanup).

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

## Dictation flow

1. `DictationCoordinator` asks `localFactory` for a `LocalTranscriber` when
   the recording starts. The model loads while you speak.
2. At stop, `LocalTranscriber.finish` decodes the saved CAF.
3. The coordinator passes the result to `TranscriptionServicing.write`
   (Gemini text cleanup, or dictionary replacements when Off).
4. If the model is still loading `TimeoutPolicy.localColdLoad` after the
   recording and a Gemini key exists, the dictation goes to Gemini and the load
   finishes as a warm-up.

History's Retry and launch recovery use `OnDeviceFirstTranscription`: the
saved recording goes to the on-device model first, then Gemini.
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
the meeting falls back to Gemini.

## Offline cleanup

FluidVoice's Fluid 1.1 Ripple and Splash cleanup models are not included.
Their terms allow use only inside official FluidVoice apps and forbid
integrating them into another app, personal use included. The open models
they are based on (LFM2.5-1.2B for Ripple, Qwen3.5-2B for Splash) could run
offline cleanup later through an MLX or llama.cpp runtime.

## Measured (cloud Mac, M4 Pro VM, 2026-11-22)

- Download: Mini 252.7 MB in 4 s, Pro 652.3 MB in 6 s, speaker model 1 s.
- Decode: median 0.25 s per dictation for both models. The first cold load
  took 1.2 s for Pro and 1.9 s for Mini. In the iOS Simulator, Pro loaded in
  2.3 s and decoded a 9.7 s dictation in 1.55 s on the CPU.
- Word error rate on 10 LibriSpeech clips (254 words): Pro, Mini and Gemini
  each 2.76%; on-device plus Gemini writing 1.97%.
- On-device plus Gemini writing took a median 1.9–2.0 s, against 2.7 s for
  Gemini from audio.
- Without the writing step, the text keeps "um" and "uh" and does not collapse
  self-corrections.
