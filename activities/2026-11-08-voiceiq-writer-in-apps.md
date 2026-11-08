# 2026-11-08: VoiceIQ Writer in the Mac and iOS apps

## Why

The owner wants a dictation to run fully offline. Fluid Speech already transcribes on device; VoiceIQ Writer ([docs/WRITER_MODEL.md](../docs/WRITER_MODEL.md)) now does the writing-rules pass on device too, as a writing option next to the providers' models.

## Outcome

- **Mac.** Settings › Writing rules has a Writing picker (provider or **On device**) and a VoiceIQ Writer 2B row with download, update and delete, like the Fluid Speech rows. The 2B runs with mlx-swift-lm on the GPU in a second instance of the speech helper. The UI process does not link MLX.
- **iPhone and iPad.** Settings › Writing offers the 2B and the 0.6B, so the owner can compare them. Both run with llama.cpp on the CPU, in-process. The speech models are released before the writer loads, and the writer is freed before the dictation ends.
- The output goes through the same gate and fallback as the cloud cleanup. History and usage name the model (`voiceiq-writer-qwen3_5-2b-local`, `voiceiq-writer-qwen3-0_6b-local`).
- With on-device transcription and writing, a dictation needs no network and no API key. iOS onboarding still asks for a key.
- GGUF builds of both sizes are new commits on the public model repos: 2B at `683b58638ad4ace63de63b28ca716690dbf42a00` and 0.6B at `4dafcd49fed095730bffb162aeba3482a1c14b8e`. The MLX files are kept.

## Decisions

- **llama.cpp on iOS, not MLX.** iOS forbids GPU work in the background voice session. MLX's CPU path runs single-threaded: the 2B took 29 s to its first token, and a float16 workaround needed about 4 GB. The parent thread chose llama.cpp for both iPhone sizes, because it has multithreaded NEON 4-bit kernels, supports Qwen3.5 and runs in the Simulator. The Mac stays on MLX.
- **Exact Q4_1 repack.** The MLX weights are affine 4-bit in groups of 64. Q4_1 is affine 4-bit in blocks of 32, so `to_gguf.py` splits each group into two blocks with the same scale and offset. The codes carry over, and only the scale and offset round from bfloat16 to float16. Bench on the Mac CPU through llama-server: 2B 40/42 and 0.6B 35/42, the same as MLX, with no answered or injected output. For each size, 41 of 42 outputs are identical to MLX's.
- **Self-built llama.cpp xcframework.** The official b12198 release xcframework has no Simulator slice (its workflow builds only macOS and iOS device) and includes Metal. `Vendor/LlamaCPU/build.sh` builds a static CPU-only `CLlama.xcframework` from the same tag, without Metal, BLAS or Accelerate, for `armv8.2-a+dotprod+fp16`. It is committed as a binary target, like WebRTCAEC. Devices without dot-product instructions (before A13) do not show the writer.
- **No prefix cache on the Mac.** Caching the 37-token prefix saved about 0.1 s but changed two or three of the 42 bench outputs, so every request prefills the whole prompt.
- **Writer in a second helper process on the Mac.** A writing pass then never waits on or interleaves with the speech exchanges. The helper keeps the 2B loaded between dictations and exits after 60 s idle.
- **iOS key gate.** `AppModel.setupBlocker` skips the key check when both models are on device. Onboarding's key page is a required step, and changing it would mean reworking onboarding, so it stays as it is.

## Verification

- `swift test --package-path VoiceIQCore`: 154 tests, 0 failures. `scripts/build.sh` and `scripts/build-ios.sh`: exit 0.
- Prompt builder against Python `common.student_user`: 300 of 300 generated cases identical in a scratch test. The rendered chat prompt equals the Hugging Face template's for both sizes.
- `SKIP_TESTS=1 scripts/release.sh`: 0.6.27 (72), `check-app-bundle.py` passed, and the app and DMG were notarized (Accepted). Installed in /Applications (Gatekeeper: Notarized Developer ID). The 2B was downloaded from Settings.
- Mac dictations in the installed app, using `say` speech played into the Jump Desktop Audio loopback, Fluid Speech Mini and On device writing:

  | Case | Transcript | Inserted | Write (first token, total) | Stop to insert |
  | --- | --- | --- | --- | --- |
  | Self-correction (first write after install) | Let's meet at three. No wait, make it four p.m. on Thursday at the coffee shop on Main Street. | Let's meet at 4 PM on Thursday at the coffee shop on Main Street. | load 1.56 s, 4.32 s, 4.57 s | 7.29 s |
  | Short list | For the trip I need to pack on my passport, the phone charger, two pairs of shoes and sunscreen. | For the trip I need to pack on my passport, the phone charger, two pairs of shoes, and sunscreen. | 0.25 s, 0.58 s | 0.97 s |
  | Email | Hi Sarah, thanks for sending the report over. … Thanks, Sirin. | The same, with "Thanks," and "Sirin" on their own lines | 0.29 s, 0.80 s | 1.34 s |
  | Question | Quick question for the team: what time does the meeting … big conference room? | Unchanged, still a question | 0.24 s, 0.62 s | 1.01 s |
  | To-do list | Things to do today. 1. Call the bank about the card. 2. … | "Things to do today:" and a numbered list, with a blank line between items | 0.30 s, 0.82 s | 1.17 s |
  | Wi-Fi off, new helper | Remind me to call the dentist on Monday, actually no, on Tuesday morning, and book a cleaning. | Remind me to call the dentist on Tuesday morning, and book a cleaning. | load 0.44 s, 0.26 s, 0.49 s | 1.29 s |

  The slow first write is MLX compiling its Metal kernels once after the install. The helper's footprint with the 2B loaded is about 1.2 GB, with a peak of 1.53 GB. MLX reports a peak of 1.21–1.24 GB. The short list stayed a sentence, which is the 2B's known `list_short_items` miss.
- iOS Simulator (iPhone 17 Pro, iOS 27.0, no API key): Fluid Speech Mini, English tools and both writer sizes were downloaded in the app. Dictations ran through the simulated mic with each size, and a scratch sampler recorded the app's footprint every 0.1 s. Measured values are in [WRITER_MODEL.md](../docs/WRITER_MODEL.md#memory-on-iphone). In runs with a 1.5 s pause between the two models, the footprint fell to 51–59 MB (resident 407–417 MB) after the speech model was released and before the writer loaded. The writer peaked at 145–156 MB for the 2B and about 117 MB for the 0.6B, and the footprint fell back to 53–62 MB after release. Simulator timings use the Mac's CPU, not an iPhone's.

## Incident: the offline test took the Mac mini off the network

The offline run turned off the Mac mini's Wi-Fi (`networksetup -setairportpower en1 off`), which is its only network link. The script turned Wi-Fi back on 37 s later, and airportd logged the request, but the remote machine did not reconnect until it was rebooted about 8 hours later. The reboot also cleared `/tmp`, which held the owner's app backup, the raw Simulator footprint logs and the test audio. The owner's settings were restored from the recorded values. The owner's earlier app build (0.6.27 (72) from `main`) was not reinstalled, so /Applications holds this branch's notarized 0.6.27 (72). Do not turn off networking on this machine for tests. Test offline behaviour another way, for example by blocking the app's own network access.

## Rollback

Set Writing back to the provider. Settings deletes the downloaded writer. Reverting the branch's integration commits removes the option. The model repos keep their earlier revisions.
