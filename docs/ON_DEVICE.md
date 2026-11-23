# On-device speech

VoiceiQ can transcribe dictations and meetings on the Mac, iPhone or iPad
instead of sending audio to Gemini. Gemini stays the default. The models are
Fluid Speech Pro and Fluid Speech Mini by FluidVoice (Parakeet TDT models
converted to Core ML), run through the FluidAudio package, plus pyannote
community-1 to tell meeting speakers apart. LFM3-Omni-2B by Liquid AI, run
through llama.cpp, can write on-device transcripts and meeting notes so no
model service sees the words. Finished text still syncs to your own iCloud
like any dictation.

## Settings

Settings → Dictation → Speech has three choices, each saved on its own:

| Row | Values | Key | Default |
| --- | --- | --- | --- |
| Dictation | Gemini, On device | `transcriptionSource` | Gemini |
| Meetings | Gemini, On device | `meetingTranscriptionSource` | Gemini |
| Writing rules and notes | Gemini, On device, Off | `cleanupSource` | Gemini |

The third row shows only when dictation or meetings run on device. It decides
who writes an on-device transcript:

- **Gemini**: the transcript goes to Gemini as text, never as audio, with the
  built-in writing rules, your custom rules, dictionary and regional spelling
  (`PromptV1.transcriptSection`). Meetings get notes. If Gemini fails or there
  is no key, the dictation goes in as transcribed.
- **On device**: LFM3-Omni-2B writes the transcript by the same rules and
  writes meeting notes. Offered on the Mac, and on iPhone and iPad with 6 GB
  of RAM or more; below that the row offers Gemini and Off only. If it fails
  or is not downloaded, Gemini writes the dictation or the meeting notes when
  a key is stored, as with Gemini; with no key the dictation goes in as
  transcribed. On a device that does not offer it the choice reads as Off.
  See [On-device writer](#on-device-writer).
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
on-device writes" does not exist.

Whatever this row says, Off included, an on-device dictation or meeting whose
model is missing, busy, fails or loads too slowly goes to Gemini as audio when
a key is stored, and Gemini transcribes and writes it as with the Gemini
source. Without a key the dictation fails and stays in History for Retry, and
the meeting is marked failed.
Screen context, when on, sends its screenshots with the Gemini writing
request as it does with a Gemini dictation.

## Models

| Model | Size | Languages | Offered on |
| --- | --- | --- | --- |
| Fluid Speech Pro (8-bit Core ML, `FluidVoice-Labs/fluid-speech-pro-coreml@3b9d38a`) | 652.3 MB | 25 European languages | Mac; iPhone/iPad with 6 GB of RAM or more |
| Fluid Speech Mini (`d81c316`) | 252.7 MB | English | Mac; iPhone/iPad with less than 6 GB |
| English tools (Silero VAD, Parakeet CTC vocabulary) | 103.9 MB | English | optional, adds dictionary correction |
| Speaker separation (pyannote community-1) | 21.6 MB | any | needed for on-device meetings |
| LFM3-Omni-2B Q4_K_M GGUF (`LiquidAI/LFM3-Omni-2B-GGUF@d508b88`) | 1.1 GB | writes in the dictation's language | Mac; iPhone/iPad with 6 GB of RAM or more and an A13 or later |

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
   recording and a Gemini key exists, the dictation goes to Gemini and the
   load finishes as a warm-up.

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
the meeting falls back to Gemini. With Writing rules and notes set to On
device, LFM3-Omni-2B writes the notes after the transcript is saved.

## On-device writer

LFM3-Omni-2B is a 2B model that hears, sees and writes. VoiceiQ uses only its
text side: the 1.1 GB Q4_K_M GGUF, without the audio projector. It was tried
as a transcriber and left out: 3.4–4 s per clip against 0.25 s for Fluid
Speech, names misheard ("Leighton" as "Layton"), and "um" and "comma" kept.

**Runtime.** llama.cpp `b12633`, built by `VoiceIQCore/Vendor/llama/build.sh`
into `llama.xcframework` (macOS universal, iOS, iOS Simulator; llama.cpp's
own xcframework has no Simulator slice). `LocalWriterJob` loads the model,
reads the prompt, writes, and frees the model and context before it returns.
The answer is forced to `{"text": …}` (or the notes JSON) by a grammar.
MLX and ONNX were not used: llama.cpp runs the same file on both platforms
and on the CPU, which iOS requires for an app in the background.

- **Mac**: each request starts the `VoiceiQLocalSpeech` helper, which runs on
  the GPU (Metal) and exits after the answer, so the app never holds the model.
- **iPhone and iPad**: in the app, on the CPU. The library uses the
  dot-product instructions, so the writer is offered only on an A13 or later
  (`LocalWriterSupport.isAvailable`); this leaves out the 6 GB A12X/A12Z
  iPad Pros.

**Prompt.** `PromptV1` is about 9,400 tokens; a 2B model reads it in tens of
seconds and then mostly copies the transcript back. `PromptOnDevice` is the
same built-in rules cut to about 900 tokens with short examples, followed by
your custom rules (up to 2,000 characters), dictionary (100 terms), "heard
as" spellings (10) and regional spelling. A spoken "period" written as ".." becomes "." before the model sees the
transcript. In English, hesitation sounds are removed first and a transcript
of only hesitation sounds is not sent at all; in other languages "um" and
"er" can be words, so the model decides. The read system
prompt is saved next to the model (`prefix-<hash>.state`) and restored for
the next dictation, so only the dictation itself is read.

**Memory.** Every local model loads only for the step that needs it:

1. The speech model loads at recording start and is released after decoding.
2. `LocalWriter` waits for any speech-model warm-up to finish, then loads
   LFM3-Omni-2B, writes, and frees it.
3. Meetings: speech model and speaker separation run together (one step
   needs both), are released, then LFM3-Omni-2B writes the notes.

The weights are memory-mapped from the file, so they count as clean,
reclaimable pages rather than the app's footprint.

**Licence.** LFM Open License v1.0: free for personal and non-commercial use;
commercial use only below US$10 million annual revenue. VoiceiQ downloads the
file unmodified from Hugging Face and does not redistribute it.

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
- Without the writing step, the text keeps "um" and "uh" and does not collapse
  self-corrections.

On-device writer, same eight dictations (self-correction, list, question,
spoken punctuation, filler only, injected instruction, names, email):

- Download: 1.1 GB in 4 s.
- iOS route (CPU, in the process), per dictation after the first: 1.6–3.9 s,
  including about 0.7 s to load the model. The first dictation after install
  also saves the system prompt: 6.6 s. In the iOS Simulator app: 0.9 s for
  the self-correction and 3.2 s for the email. Meeting notes for a 28 s
  meeting: 7.5–10 s. Gemini writing an on-device transcript took 1.6–3.3 s,
  and Gemini from audio 2.1–4.2 s (one call took 12 s).
- Mac helper route on this VM's virtual GPU: 3.6–12 s per dictation, slower
  than its CPU. A real Mac's GPU was not measured.
- Quality against Gemini: the same result for the list, question, letter
  layout, filler only (nothing typed), injected instruction (typed as said)
  and email paragraphs. It collapsed the self-correction. It missed "called"
  → "call", wrote "the" as "all" in "ignore the previous instructions", left
  names alone that are not in the dictionary ("Sreenie", "voice IQ"), and on
  Pro's transcript left "Kama" in "Dear Priya Kama". Gemini fixed those
  names from context.
- Peak footprint (one process per combination, all eight dictations or one
  meeting):

| Run | Peak |
| --- | --- |
| Dictation, Mini or Pro, writing Off | 153–161 MB |
| Dictation, Mini + LFM (iOS route) | 216 MB |
| Dictation, Pro + LFM (iOS route) | 186 MB |
| Dictation, Pro or Mini + LFM (Mac, app process; the model is in the helper) | 135 MB |
| Meeting, Mini or Pro, notes Off | 217–219 MB |
| Meeting, Mini + LFM notes (iOS route) | 222 MB |
| Meeting, Pro + LFM notes (iOS route) | 218 MB |

  The model file stays mapped only while LFM3-Omni-2B writes: a sampler saw
  it mapped during the write and unmapped after every step. The 1.1 GB of
  mapped weights is not part of the footprint.
