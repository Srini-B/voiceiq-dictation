# 2026-11-05: Dependency upgrades (FluidAudio 0.18.2, Sparkle 2.10.1, GRDB 7.12, Peekaboo 4.9.7)

## Why

The owner asked to bring the app's dependencies up to date where it helps.

- FluidAudio 0.18 repairs long-form decoding: it recovers dropped opening
  speech (#1056) and re-decodes short gaps at chunk seams (#1061). Fluid
  Speech Mini and Pro use that path for dictations over five minutes and for
  meetings. 0.18.2 rather than 0.18.1: 0.18.1 crashes processes that
  enumerate Objective-C classes on macOS 26 and earlier when built with the
  27 SDK.
- Sparkle 2.10.1 drops a stale `sparkle:format` when `generate_appcast`
  embeds HTML release notes, which `scripts/publish-github-release.sh` does.
- GRDB 7.12 brings upsert, WAL snapshot and deadlock fixes.
- Peekaboo was pinned to a bare revision under the claim that it has no
  tagged releases. It has had tags since v1.0.0.

## What changed

- `VoiceIQCore/Package.swift`: FluidAudio `exact: "0.18.2"` with traits
  `["NemoTextProcessing", "Diarizer"]`. 0.18 added `TTS` and `Diarizer`
  traits that are on by default, and listing traits turns the defaults off.
  `Nemotron3Diarizer` is behind `#if Diarizer`, so the meeting diarizer needs
  that trait. `TTS` stays off. GRDB `from: "7.12.0"`.
- `project.yml`: Sparkle `from: 2.10.1`; Peekaboo `exactVersion: 4.9.7`
  (was revision `31d67ea`, 228 commits behind), which brings AXorcist 0.2.2
  and Commander 0.3.0.
- `scripts/trim-inference-resources.py` and its two build phases (Mac speech
  helper, iOS app) are removed. With `TTS` off, FluidAudio builds no
  resource bundle: neither `FluidAudio_FluidAudio.bundle` (0.17.7) nor
  `FluidAudio_LuxTtsG2pResources.bundle` (0.18.2 with `TTS`) appears in the
  helper, the Mac app or the iOS app. `scripts/check-app-bundle.py` now
  rejects any `FluidAudio_*.bundle`, so turning `TTS` back on fails the
  release check.
- The speech helper binary shrank from 43.3 MB to 38.1 MB because TTS code
  is no longer compiled.
- No source changes. The app's FluidAudio calls (`AsrModels.loadLocal`,
  `AsrManager.transcribe` and `transcribeDiskBacked`, `CtcModels`,
  `VocabularyRescorer`, `ctcTokenRescore`, `TextNormalizer`,
  `Nemotron3Diarizer`) compile unchanged.

## Verified

Resolved versions (Xcode release build): FluidAudio 0.18.2, GRDB 7.12.0,
Sauce 2.5.2, Sparkle 2.10.1, Peekaboo 4.9.7, AXorcist 0.2.2, Commander 0.3.0.

A/B of 0.17.7 against 0.18.2 on the M2 Mac mini. A scratch package built
`VoiceIQInference` twice (repository HEAD and this change) and ran the app's
own entry points: `LocalSpeechInference.makeSession` with CPU encoder (the
dictation path; over five minutes it is `transcribeDiskBacked`) and
`LocalSpeechInference.transcribeMeeting` (meeting path, Neural Engine).
Audio: LibriSpeech test-clean chapters joined with 0.3 s gaps (four of
8.3 to 8.6 min, one of 3.8 min), and an 11.6 min chapter with 4 to 12 s and
20 s pauses. Models: the installed Fluid Speech Mini and Fluid Speech Pro.
WER is on lowercased words without punctuation, against the LibriSpeech
reference; digits count as errors in both versions.

| Clip | Mini 0.17.7 | Mini 0.18.2 | Pro 0.17.7 | Pro 0.18.2 |
|---|---:|---:|---:|---:|
| long1 (8.4 min) | 4.18 % | 4.03 % | 4.92 % | 4.77 % |
| long2 (8.6 min) | 1.62 % | 1.53 % | 1.71 % | 1.62 % |
| long3 (8.3 min) | 2.58 % | 2.51 % | 2.65 % | 2.58 % |
| long4 (8.4 min) | 2.98 % | 2.98 % | 3.05 % | 3.05 % |
| pauses (11.6 min) | 1.46 % | 1.46 % | 1.77 % | 1.77 % |
| short (3.8 min, in memory) | 1.98 % | 1.98 % | 2.14 % | 2.14 % |
| All, 6,789 words | 2.61 % | 2.55 % | 2.86 % | 2.80 % |

Meeting path, Mini: long1 4.25 % to 4.18 %, pauses unchanged at 1.46 %.
Every difference is at a chunk seam. 0.17.7 doubled a word ("a white white
suckling", "writing writing") or dropped a repeat ("no, no" for "no, no,
no", "well I" for "well, well I"); 0.18.2 got all four right. No clip got
worse. The meeting diarizer gave identical words and speaker stretches in
both versions on a 53 s two-speaker clip.

Dictionary correction (CTC rescoring with the English tools pack): seven
`say` clips with a 12-term dictionary gave identical output in both
versions ("voice EQ" to "VoiceiQ", "Rini" to "Srini", "tail scale" to
"Tailscale"). With five terms on one clip, 0.17.7 applied "BlueLobster" and
0.18.2 applied "VoiceiQ"; with each term alone both versions agree, so 0.18.2
matches the single-term results (FluidAudio #1041 changed how candidates
share an acoustic match). The 24 newest real dictations (810 s) replayed with
the user's dictionary gave identical text in both versions.

Builds and tests:

- `scripts/test.sh`: 143 tests, 0 failures.
- `scripts/build-ios.sh` (Simulator, own derived data): succeeded, before
  and after removing the trim phase. The app launched on an iPhone 18 Pro
  Max simulator to its Home screen and was still running 15 s later.
- `scripts/release.sh`: tests, Developer ID build, `check-app-bundle.py`,
  signature checks, app and DMG notarization (Accepted) and stapling all
  passed for 0.6.24 (69).
- Installed from the DMG to `/Applications`; Gatekeeper: "Notarized
  Developer ID". It launched and stayed running.
- A dictation through the installed app (`say` speech into the Jump Desktop
  Audio loopback, `voiceiq://start-hands-free` and `voiceiq://stop`)
  transcribed locally with Fluid Speech Mini (14.5 s, model
  `fluid-speech-mini-local`, vocabulary loaded) and was inserted.
- The installed helper, driven over its pipe protocol as the app drives it,
  transcribed the 8.4 min clip with `transcribeDiskBacked` (identical to the
  0.18.2 A/B output) and ran a meeting with the Nemotron diarizer (2
  speakers, 12 stretches).
- Agent mode: ⌃⌥G and a spoken command produced a Peekaboo observation
  ("Looking at Safari, … 89 elements"). The model call then failed with
  "Missing API key" (401), as the last run on 2026-10-21 did, so Peekaboo's
  action layer was not exercised.
- No new VoiceiQ or helper crash reports.

## Rollback

Revert this change: restore FluidAudio `exact: "0.17.7", traits:
["NemoTextProcessing"]`, GRDB `from: "7.0.0"`, Sparkle `from: 2.10.0`,
Peekaboo `revision: 31d67ea858bcd9824f9f8cfe5bb105cc4ff53783`, and
`scripts/trim-inference-resources.py` with its two build phases (0.17.7
always builds the LuxTTS resource bundle). Each item reverts on its own.
Package.resolved is not tracked. FluidAudio and Peekaboo are exact pins, so
the next build resolves the old versions. GRDB and Sparkle are minimum
versions: the old lines still resolve the newest 7.x and 2.x, so going back
to an older release needs an exact pin.
