# Deleting a model removes Core ML's prepared copies

2026-11-23. Not released.

## Why

cyron, on 0.7.13 (87) on the Mac: after one dictation with the on-device
models he deleted both (Fluid Speech and the LFM3 writer) and switched to
Gemini, yet `~/Library/Caches/io.blue.voiceiq.localspeech` still held about
1.1 GB.

## Cause

That folder is the caches folder of the `VoiceiQLocalSpeech` helper, the
process that loads the models on the Mac (its bundle id is
`io.blue.voiceiq.localspeech`). On a model's first load Core ML writes a
prepared copy for this device into
`com.apple.e5rt.e5bundlecache/<OS build>/<key>.bundle` there (measured on the
Mac mini, 2026-10-26); llama.cpp's Metal backend may add a small shader
cache. The GGUF is not copied: llama.cpp maps it from `Models`. Deleting a
model removed only `Application Support/VoiceiQ/Models/<model>`. The
cloud-only build (2026-11-10) deleted this folder at every launch
(`FileLayout.removeRetiredModels`); bringing the models back (e0b9884) removed
that cleanup and added none to the delete. Nothing needs the folder once the
models are gone; Core ML rebuilds it on the next load.

## What changed

- `LocalModelInstaller.removeAll`, which a model's Delete runs, also removes
  the prepared-model cache: on the Mac the helper's whole caches folder, on
  iOS the app's `com.apple.e5rt.e5bundlecache`. Core ML keeps no per-model
  index, so models still downloaded are prepared again on their next load
  (a slower first dictation).
- At launch, with no model downloaded, the same cache is removed
  (`FileLayout.removeStaleFiles`, renamed from `removeStaleRenders`). This
  clears what 0.7.13 and earlier left.
- Test: `OnDeviceDictationTests.testPreparedModelsGoWithTheModels`.

## Not checked here

Written in an orb with no Swift toolchain; CI runs the package tests and both
app builds on Xcode 27. Not tried on an installed signed build.
