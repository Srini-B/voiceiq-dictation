# Whistle native evaluation

2026-10-09. The user requested Whistle for supported Apple devices and asked
whether Needle could handle cleanup. No application code or installed app
was changed during this evaluation.

## Compatibility blocker

VoiceiQ targets macOS 14 and iOS 17. Downloaded the official Needle 3 libraries
at revision `2ae11323dc000f5e70c49f7403efa6af12ba9e67` and inspected their Mach-O
build-version commands with `otool -l`:

| Library | Architecture | Declared minimum |
| --- | --- | --- |
| macos-arm64/libneedle.a | arm64 | macOS 26.0 |
| ios-arm64/libneedle.a | arm64 | iOS 27.0 |
| ios-sim-arm64/libneedle.a | arm64 | iOS Simulator 27.0 |

The previous speech-capable snapshot, `f84005f8992caf37f17b0d64a4b5b31a84ce0d2a`,
has the same minimum versions and lacks the new streaming API. The published
Apache Needle repository contains Python code and bindings, not the native
production engine source needed to rebuild for older deployment targets.
There is no published Intel Mac static library in this distribution.

Do not lower Mach-O minimum-version metadata or raise VoiceiQ's minimum OS
silently. Full integration requires compatible vendor builds, or a decision
to expose Whistle only on the newer supported OS versions while keeping cloud
transcription on older versions.

## Native smoke checks

Built a temporary C++ command-line probe linked directly to the pinned native
library, without Python, automatic downloads, or telemetry. Loaded Whistle
revision `b358ddadd89b7a713b5aa131f23032d3cca1b251`; verified the archive SHA-256
`b6e02f048568ac5d01a2042556c658061e699acbc0aa2a1439f52f3d461dffeb`.
Converted synthetic English Samantha speech to 16 kHz mono Int16 PCM and then
normalized float PCM for the C API. Keywords included Priya and VoiceiQ.

- Mac mini, macOS 26.6.2: one-shot output matched the 4.32-second sample,
  "Send the revised report to Priya by Thursday. Sorry, make that Friday."
- Streaming on the Mac mini changed "the revised report" to "a revised
  report". An exact-transcript assertion failed. This was not an accuracy pass.
- A 38.9-second stream containing nine repetitions retained nine instances of
  the Friday correction, across the 30-second one-shot limit. It changed some
  articles and sentence boundaries. This checks continuity, not long-form
  natural-speech quality.
- Three seconds of zero PCM returned no committed text.
- The same native streaming probe completed on the MacBook, macOS 27.0.1,
  and on iPhone 17e and iPad Pro 13-inch M5 simulators running iOS 27.0.
- No physical iPhone or iPad test was performed. Simulator runs used the Mac's
  CPU, not device hardware. One freshly booted iPad simulator run was much
  slower than the iPhone simulator; no device performance conclusion is drawn.
- All timings exclude cloud cleanup, capture finalization, and UI insertion.
  These are functional probes, not a comparative or end-to-end benchmark.

Review output is in `.amp/in/artifacts/whistle-evaluation/`. Probe code and
generated input are retained there so the result can be reproduced against
the pinned libraries. Temporary downloaded runtime/model files were removed.
The iPad simulator started for this check was shut down afterward.

## Needle is not a cleanup model

The official Needle integration contract says no free text is generated. It
returns tool calls, structured extraction, and tool results. System prompts
hold facts, not general rewriting instructions. Its text model has no image
input. Giving it a `cleaned_text` tool schema would not establish that it can
follow VoiceiQ's detailed cleanup rules or interpret screenshots.

Keep cleanup with the selected Gemini/OpenAI writing model. Needle could be
evaluated separately for local command routing or field extraction, neither
of which was implemented here.

Sources:

- [Whistle model card](https://huggingface.co/Cactus-Compute/whistle)
- [Pinned native API](https://huggingface.co/Cactus-Compute/needle3/raw/2ae11323dc000f5e70c49f7403efa6af12ba9e67/macos-arm64/needle.h)
- [Needle integration contract](https://github.com/cactus-compute/needle/blob/main/llms.txt)
- [Needle downloads](https://github.com/cactus-compute/needle/blob/main/needle/agent/fetch.py)

## Delivery

Whistle remains a prototype, not an app option. The installed real-time cloud
builds are untouched. No release, commit, or push was made for this evaluation.
