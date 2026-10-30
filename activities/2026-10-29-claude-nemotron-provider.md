# 2026-10-29: Claude + Nemotron provider

## Why

The owner wants one transcription model and one writing model in place of
the Gemini, OpenAI and on-device choices: NVIDIA Nemotron 3.5 Transcribe
(released 2026-10-28) for dictation and meetings, and Claude for cleanup,
Ask Anything, Translate, meeting notes and agent mode. Nemotron 3.5
Transcribe is a 30B mixture-of-experts speech LLM (about 4.3B active), too
large for an 8 GB Mac or an iPhone, so it runs on DeepInfra at $0.002 per
audio minute. This change adds the provider beside the others. Removing the
others is a separate step, after the owner confirms.

## Decisions

- One provider, `ModelProvider.anthropic` ("Claude + Nemotron"), with two
  keys: Anthropic and DeepInfra. `KeychainStore.hasKey(for:)` needs both.
  `GeminiClient.applyAuth` sends each key only to its own host.
- Models (`AnthropicConfig`): `claude-haiku-5-5` writes, because cleanup sits
  on the dictation's critical path; `claude-sonnet-5-5` runs agent mode,
  which clicks by screenshot pixel. No override fields yet.
- Claude 5.5 rejects `temperature` ("deprecated for this model"), so writing
  requests send none.
- With screenshots, the rules go in `system` and the user turn carries the
  screenshots and the dictation, the layout measured for OpenAI on
  2026-09-28 (`GeminiClient.dictationSplit`).
- DeepInfra has no speaker labels: the `<spk:N>` instruction sent as
  `prompt` came back as plain text, and the model is not on its chat
  completions (404). Meetings label words by track
  (`MeetingTranscriber.labelByTrack`): on a call, the owner and one far-side
  speaker; off a call, one speaker. See docs/MEETINGS.md.
- No live transcription on this provider; the saved recording is sent when
  dictation stops (`LiveTranscriber` returns nil).
- `OpenAIKeySection` became `ProviderKeySection`, one view for the OpenAI,
  Anthropic and DeepInfra keys. Onboarding still offers only the
  single-key providers; Claude + Nemotron is set up in Settings → Advanced.

## Verification

- Live API probe through the real `VoiceIQCore` code with the owner's keys:
  dictation 1.9–2.4 s with a dictionary word spelled as given; cleanup 3.0 s;
  cleanup with a screenshot 1.8 s; French translation 1.6 s; a synthetic
  41 s two-person Zoom call split into six correct You/far-side turns in
  7.4 s; meeting notes parsed with decisions and actions in 8.2 s; an agent
  turn on Sonnet with a screenshot called `done` correctly, and the second
  call read 5,455 tokens from Anthropic's cache.
- `swift test` in VoiceIQCore: 143 tests pass. The Mac app (Debug) and the
  iOS app build.
- A signed and notarized 0.6.12 (57) release was installed. In Settings →
  Advanced, Claude + Nemotron showed the Anthropic and DeepInfra key
  sections; both keys validated against the live APIs and were saved.
  History → Retry on a 13 s dictation ran `call transcribe via anthropic
  (nvidia/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B)` in 2.3 s and `call
  cleanup via anthropic (claude-haiku-5-5)` in 2.1 s. The row booked
  $0.0002 for transcription and $0.0132 for cleanup (12.0k tokens in).

## Open

- Correction, later on 2026-10-29: the $0.0132 above came from wrong Haiku
  prices. They were copied from DeepInfra's catalog ($1.00 in, $5.00 out,
  which is Haiku 4.5) instead of Anthropic's page ($0.10 in, $0.50 out for
  prompts up to 100k tokens). At the real price that dictation cost about
  $0.0012, below Gemini 3.8 Flash's $0.0021. Sonnet and Opus cache reads were
  also corrected to 0.05x input. Rows already booked keep the old figure.
- Prompt caching and far-side diarization were added the same day; see
  `2026-10-29-meeting-notes-fixes.md`.

## 2026-10-30: PR #30 review fixes

CodeRabbit's eight findings were all real and are fixed:

- ⌘Esc with a Command trigger: the ⌘ press begins finalizing, so the Esc
  cancel found no capture, read 0 s and discarded recordings of any length.
  The cancel now waits for the pending engine stop and keeps long recordings
  with Retry. A scratch test failed without the fix (60 s recording
  discarded) and passed with it; it was deleted afterwards.
- Meetings: windows are 240 s whenever a DeepInfra key is saved, since any
  failed window can fall back to it, and the far side is diarized on the Mac
  whenever it came back as one voice.
- Privacy: Settings on Mac and iPhone and `docs/PRIVACY.md` name every
  provider a meeting can fall back to; Claude + Nemotron never streams audio.
- Keyboard: a layout change cancels held touches (stale key indices, a
  running delete timer); leaving a digit-pad field returns to letters; Reset
  Keyboard Learning also clears the words the running extension holds; words
  typed in code, card-number and no-correction fields are not learned.

Greptile's second pass (its first two runs errored) found five more, all real:

- A slow cancel could act on the next recording: `.cancelled` accepts a new
  begin while the old stop drains. The keep-or-discard now runs on the session
  that was cancelled. A scratch test (cancel, begin, slow stop) left the new
  recording stuck before the fix and finished it after; deleted afterwards.
- The owner-overlap pass now goes in windows of the main pass's size, so a
  long call's double talk stays within DeepInfra's timing limit.
- Predictions off no longer turns off Auto-Correction and Text Replacements;
  it only hides the bar.
- A slid word or correction is forgotten when the text before the cursor no
  longer matches the keyboard's last edit (the user moved the cursor).
- Keys answer VoiceOver's activate with the same tap the touches deliver.

Not run on the keyboard in the Simulator this round (the software keyboard
would not come up); both apps build and the 143 core tests pass.
