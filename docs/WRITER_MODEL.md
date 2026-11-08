# VoiceIQ Writer: the on-device writing model

VoiceIQ Writer is a small English model that does the writing step offline: it turns a raw transcript into the text the speaker meant to type, as Claude Sonnet 5.5 does today with `PromptV1.cleanupPrompt`. The Mac and iOS apps offer it as the "On device" writing option. This page covers how it is built, how it scores and how the apps run it.

## How it is built

The model is distilled from the production cloud cleanup. The pipeline is in [scripts/writer-model](../scripts/writer-model/README.md).

1. **Inputs.** 14,638 raw dictations sampled from 11 public datasets (inputs only, never their cleaned outputs), and 10,944 raw dictations written by Claude Sonnet 5.5 for the categories public data barely covers: corrections, lists, numbers, emails and chat, sound-alikes, long dictations, spoken punctuation, requests to an AI, injection attempts, clean input and spelled identifiers. About half of the inputs read like a cased, punctuated recognizer (Parakeet, Whisper), and half are lower case without punctuation. About a quarter carry the prompt's context: a vocabulary list (13%), the app and window title (10%) or the text around the cursor (4%).
2. **Targets.** Every input goes through Sonnet 5.5 with the exact production prompt. `common.teacher_request` rebuilds the request from `PromptV1.swift` and `DefaultWritingRules.swift`, with the same system/user split and one-hour cache breakpoint as `GeminiClient.anthropicMessage`. Labelling used the Message Batches API.
3. **Filters.** `filter.py` drops a target when the ported `ValidationGate` rejects it or when it has a banned form: dashes, preambles, labels, prompt or tag leaks, or a heading or subject line the speaker did not dictate. It drops any row that overlaps the 42 benchmark cases (a shared 13-word sequence, or MiniLM-L6 cosine of 0.65 or more against a case's RAW) and exact duplicates. 25,116 of 25,500 rows remain: 24,116 train, 400 valid and 600 test. A second round added 3,516 inputs aimed at the rules the first model still broke, written by Claude Haiku 5.5 and labelled the same way; 3,472 remain (3,262 train, 70 valid, 140 test).
4. **Training.** LoRA (rank 32, scale 2, all layers, examples up to 1,024 tokens) with mlx-lm on a Mac mini M2 with 16 GB. The student sees a short system prompt (`system.txt`, 25 tokens) and a user turn `RAW: <transcript>`, optionally preceded by `Vocabulary:`, `Place:` and cursor lines. The 8k-token rules prompt is not needed at inference.

### Training Qwen3.5 on 16 GB

mlx-lm 0.32 trains Qwen3.5's gated-delta (linear-attention) layers with a per-token loop, because the Metal kernel has no gradient. The loop keeps one state per token for the backward pass: about 1.7 GB per 256 tokens on Qwen3.5-2B, at about 45 tokens/s, and a batch of one 1,536-token example runs out of memory. `chunked_gdn.py` replaces it during training with the chunked form of the same recurrence, written in MLX ops so autograd does the backward pass. The intra-chunk correction (I + M)⁻¹ uses blocked inversion; a power series in M is exact on paper but turns NaN on real activations, whose keys are nearly parallel. The result matches mlx-lm's reference to about 1e-6 on outputs, final state and gradients (including a nearly-parallel-keys case) and matches the Metal kernel's training loss within 0.5% on real batches. On the M2 it runs at about 130 tokens/s on real data, and 1×1536 fits in 6.6 GB. Inference keeps the Metal kernel.

## Results

The shipped model is **[`cyron/voiceiq-writer-qwen3_5-2b`](https://huggingface.co/cyron/voiceiq-writer-qwen3_5-2b)** (public, revision `0efe70d13ec7981acd39e36a537d2e628bd36dbb`): Qwen3.5-2B, MLX 4-bit (group size 64), 1.06 GB of weights. It passes 40 of the 42 held-out benchmark cases with no answered or injected output, against 26/42 for the best off-the-shelf model and 18/42 for untuned Qwen3.5-2B with the full production prompt.

Measured on the Mac mini (M2, 16 GB) with `bench.py`: greedy decoding, the 25-token system prompt prefilled once and cached, and the student's short prompt for every fine-tune.

| Model | Bench | Answered or injected | Held-out gate ok (600) | Similarity to Sonnet (600) | Median total | Cached TTFT | Gen tok/s | Peak GB |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| **Qwen3.5-2B, 4-bit (shipped)** | **40/42** | 0 | 599/600 | 0.874 | 0.33 s | 0.10 s | 76 | 1.24 |
| Qwen3.5-2B, bf16 | 39/42 | 0 | | | 0.89 s | 0.16 s | 24 | 3.91 |
| Qwen3-0.6B round 1, bf16 | 36/42 | 0 | 599/600 | 0.882 | 0.31 s | 0.06 s | 71 | 1.32 |
| Qwen3-0.6B round 1, 4-bit | 35/42 | 0 | 599/600 | 0.871 | 0.13 s | 0.04 s | 195 | 0.53 |
| Qwen3-0.6B round 2, 4-bit | 35/42 | 0 | 597/600 | 0.855 | 0.13 s | 0.04 s | 195 | 0.53 |
| superwhisper/s1-mini, own prompt | 26/42 | 0 | | | | | | |
| Qwen3.5-2B untuned, production prompt | 18/42 | 1 | | | | | | |

- The shipped model fails `list_short_items` (a short shopping list written as plain lines instead of bullets) and `word_order` ("log in with my phone to the admin panel" kept as spoken).
- The one held-out gate rejection is the same for every fine-tune: a dictated injection-style question written without its question mark.
- On the 140-case targeted held-out slice (short lists, parentheses, sound-alikes, spelled identifiers, word order, money, changes of mind), the shipped model has 140/140 gate ok, 44% exact and 0.957 similarity.
- The 4-bit build scores higher than bf16 on the bench by one case. Treat a one-case difference as noise.
- Its weakest held-out categories by similarity to Sonnet are recipe dictations (0.60), human-transcribed disfluent speech (0.68) and long rambling voice notes (0.68).
- Validation loss tracked the bench poorly. Qwen3-0.6B's checkpoint with the lowest validation loss scored 34/42, below the final checkpoint's 35/42.

### Runs

| Run | Data | Steps | Mac time | Final val loss |
| --- | --- | --- | --- | --- |
| Qwen3-0.6B round 1 | 24,105 main rows, one epoch | 6,026 × 4 | 4 h 12 min | 0.125 |
| Qwen3-0.6B round 2 | resumed; 3,262 targeted + 3,262 main | 1,631 × 4 | 55 min | 0.112 |
| Qwen3.5-2B (shipped) | 3,262 targeted + 10,000 main, one epoch | 3,316 × 4 | 6 h 26 min | 0.107 |

The second round targeted what Qwen3-0.6B still got wrong. It fixed parentheses and money words on 0.6B but cost general quality (casual conversation similarity fell 0.157), so the 2B mix keeps the targeted rows inside a larger sample of the main set. A 200-step A/B chose raw Qwen3.5-2B over `Kayetic/super-cleanup-qwen3.5-2b` as the 2B base: 0.078 against 0.085 validation nats per character. Super-cleanup is published only as 4-bit weights with a 55k-token vocabulary.

## Costs

Teacher and generator calls, from the logged usage fields at PriceBook prices (batch at half price):

| Item | Calls | Cost |
| --- | --- | --- |
| Teacher targets, Sonnet 5.5, Batches API | 25,500 | $50.45 ($0.00198 each: 11.4k cached prompt tokens, 442 input, 193 output) |
| Synthetic inputs, Sonnet 5.5 | 643 | $26.66 |
| Second-round inputs, Haiku 5.5 | 176 | $0.37 |
| Second-round targets, Sonnet 5.5, Batches API | 3,516 | $5.11 |
| Cache warm-up and checks | about 10 | about $0.30 |
| **Total** | | **about $82.90** |

Training and evaluation ran on the Mac mini; no cloud GPU was used.

## In the apps

The cloud cleanup stays the default. Settings › Writing rules (Mac) and Settings › Writing (iPhone and iPad) add a picker between the provider's writing model and **On device**, and a download row per size that works like the Fluid Speech rows: anonymous download from the public repo, pinned to a revision with byte sizes and SHA-256 digests (`LocalWriterManifest.swift`), verified in a staging folder, update and delete in place. Nothing downloads on its own. The Mac offers the 2B. iPhone and iPad offer the 2B and the 0.6B, so the two can be compared on a real device, and only on chips with the dot-product instructions the llama.cpp build needs (A13 and later).

When **On device** is selected and the size is downloaded, `cleanupOrFallback` (`GeminiTranscriptionService+Cleanup.swift`) runs the writer instead of the provider's request. The output goes through `ValidationGate.stripArtifacts` and `validate` and the same `settle` fallback as the cloud path, so a rejected or failed output inserts the transcript. On the question-answered rejection there is no reminder retry. History records the model as `<transcription model>+voiceiq-writer-qwen3_5-2b-local` (or `…-qwen3-0_6b-local`), and usage records a cleanup row with the prompt and generated tokens at $0. If the size is not downloaded, the provider writes. Translate, Ask Anything, Agent and meeting notes always use the provider.

The prompt carries the dictionary as `Vocabulary:`, the app, window title and page as `Place:`, and the field text as the cursor lines when Fit to existing text is on. Custom writing rules and the spelling-variant line do not reach the model, which learned the default rules only; the settings footer says so.

With on-device transcription and on-device writing, a dictation needs no network and no API key. On the Mac nothing blocked this before: dictation never required a key. On iPhone, the keyboard's setup check (`AppModel.setupBlocker`) no longer asks for a key when both models are downloaded and selected (or writing rules are off). Onboarding still asks for a provider key, because its key page is a required step; an owner who wants a keyless phone gets past it once by adding any key.

### Runtimes

| | Mac | iPhone and iPad |
| --- | --- | --- |
| Runtime | mlx-swift-lm 3.32.3 (`MLXLLM`), GPU | llama.cpp b12198, CPU only |
| Weights | MLX 4-bit, revision `0efe70d` | GGUF Q4_1 repacked from the MLX weights |
| Process | a second instance of the speech helper (`VoiceiQLocalSpeech`) | the app, in the background voice session |
| Lifetime | stays loaded between dictations; the helper exits after 60 s idle | loads per dictation and is freed before the dictation ends |

The `LocalWriterSession` protocol and `LocalSpeechInference.makeWriter` keep both runtimes in `VoiceIQInference`, so the Mac UI process never links MLX. `scripts/check-app-bundle.py` checks that the Mac app's main binary has no MLX symbols and no `Cmlx` bundle, that the helper has both, and that the iOS app links llama.cpp with no Metal backend and no MLX.

The Mac writer runs in its own helper instance (`ParakeetHelperClient.writer`) so a writing pass never interleaves with a dictation's speech exchanges. It renders the prompt with the bundled chat template and `enable_thinking: false` and decodes greedily. It does not cache the system-prompt prefix: in a spike that matched Python mlx-lm token for token, the split prefill changed two or three of the 42 bench outputs to save about 0.1 s.

In the installed, notarized app on the Mac mini (M2, 16 GB), with Fluid Speech Mini transcribing, the 2B's first write after a new install took 1.56 s to load and 4.32 s to its first token (MLX compiles its Metal kernels once). A fresh helper with compiled kernels loads in 0.44 s. Warm, the first token comes in 0.24–0.30 s and the write finishes in 0.49–0.82 s, and a whole dictation (stop to insert) takes 0.97–1.34 s. The helper's footprint is about 1.2 GB with the 2B loaded and peaks at 1.53 GB; MLX reports 1.21–1.24 GB peak.

iOS forbids GPU work in the background, and MLX's CPU path runs single-threaded (29 s to first token for the 2B in a spike), so iPhone and iPad use llama.cpp instead. `Vendor/LlamaCPU/build.sh` builds `CLlama.xcframework` from llama.cpp b12198 (`f477f795`) with Metal, BLAS and Accelerate off, `armv8.2-a+dotprod+fp16`, and slices for iOS arm64 and the Simulator. The official release xcframework has no Simulator slice and carries Metal. `LlamaWriterSession` sets `n_gpu_layers = 0`, turns KV and op offload off, and uses one thread per performance core (`hw.perflevel0.physicalcpu`).

### GGUF builds

`scripts/writer-model/to_gguf.py` dequantizes the MLX weights (exact), converts them with llama.cpp's `convert_hf_to_gguf.py`, quantizes to Q4_1, then rewrites each Q4_1 block from the MLX grid: a 64-group splits into two 32-blocks that share its scale and offset, so the 4-bit codes carry over unchanged and only the scale and offset round from bfloat16 to float16. Both GGUFs are new commits on the existing repos; the MLX files stay.

| Size | Revision | File | Bytes | SHA-256 |
| --- | --- | --- | --- | --- |
| 2B | `683b58638ad4ace63de63b28ca716690dbf42a00` | `voiceiq-writer-qwen3_5-2b-q4_1.gguf` | 1,188,953,728 | `5cc57b8b0bf4f85cb6b9ed38abcd40b25f8963169cb5ec9352ad82bc73e3b0fa` |
| 0.6B | `4dafcd49fed095730bffb162aeba3482a1c14b8e` | `voiceiq-writer-qwen3-0_6b-q4_1.gguf` | 378,703,584 | `6703b323576659b92d9a6fedc9f43211a2630cfd04675d870a71f5bb654cd6b4` |

`bench/bench_llama.py` runs the bench through `llama-server` on the Mac CPU (`-ngl 0`) with the app's prompt text, greedy decoding and the same stop tokens. The 2B scores 40/42 and the 0.6B 35/42, the same as MLX, with no answered or injected output. For each size, 41 of the 42 outputs are identical to MLX's (on the 2B the one that differs is `long_status`). On the M2 CPU with 4 threads, the median total is 1.12 s for the 2B (45 tokens/s) and 0.38 s for the 0.6B (128 tokens/s).

### Memory on iPhone

A dictation never holds the speech model and the writer at once:

1. The dictation stops and Parakeet with the English tools CTC decodes the transcript.
2. `LocalTranscriber.finish` releases both speech models.
3. `LocalModelWarmup.alone` waits for any warm-up, then holds warm-ups and the next dictation's load while the writer loads, writes and is freed (`llama_model_free`).

Footprint in the iOS Simulator (iPhone 17 Pro, 2026-11-08). Footprint leaves out the memory-mapped weights, so resident size is shown too:

| Phase | Footprint | Resident |
| --- | --- | --- |
| Idle | 48–62 MB | |
| Parakeet decoding | 110–119 MB | about 1.66 GB |
| Speech model released, writer not loaded | 51–59 MB | 407–417 MB |
| 2B writing | 145–156 MB | about 1.63 GB |
| 0.6B writing | about 117 MB | about 840 MB |
| Writer freed | 53–62 MB | about 450 MB |

The Simulator runs on the Mac's CPU (M2), so its timings are not iPhone timings. There, the 2B loads in 0.17–0.81 s, reaches its first token in 0.83–0.97 s and finishes in 1.26–1.77 s; the 0.6B takes 0.09–0.27 s, 0.28–0.34 s and 0.49–0.67 s.

### Files

The Mac's files at revision `0efe70d13ec7981acd39e36a537d2e628bd36dbb` (the README is not needed on device):

| File | Bytes | SHA-256 |
| --- | --- | --- |
| `chat_template.jinja` | 7,755 | `273d8e0e683b885071fb17e08d71e5f2a5ddfb5309756181681de4f5a1822d80` |
| `config.json` | 2,625 | `8893a91e9b7763d7b94c6db181f5b7c79c6f4881a69cefb11549eefcab1823bf` |
| `model.safetensors` | 1,059,404,951 | `a7111ba73a1c0b35e741d84258dd785daa1523260222a65ec72263fb280cf68c` |
| `model.safetensors.index.json` | 60,786 | `3b2dffa510d1d73decdbc12d5e1bc7d6a9f7b2deb631bfd84238a1f8fc4e0fd1` |
| `tokenizer.json` | 19,989,339 | `a5cd9732badce41de57e6efce8302930ded1c1188c5f81feb2bd6c24c4a1941f` |
| `tokenizer_config.json` | 1,501 | `86f01837a638275f2d3479804e79802aaff0e3ccef15e5f29dd6afbe6551daed` |

Qwen3-0.6B ([`cyron/voiceiq-writer-qwen3-0_6b`](https://huggingface.co/cyron/voiceiq-writer-qwen3-0_6b), 35/42 at 4-bit) has standard attention and a third of the weights. Its MLX files at revision `2c328e68fc4c6e902682304a34263aeb3c23bbdd`, from which its GGUF was built:

| File | Bytes | SHA-256 |
| --- | --- | --- |
| `chat_template.jinja` | 4,168 | `a55ee1b1660128b7098723e0abcd92caa0788061051c62d51cbe87d9cf1974d8` |
| `config.json` | 1,021 | `d8cbd096f758add51a940656710a0319cfb3ad4ae4591507ab29c2e8bebecc54` |
| `generation_config.json` | 113 | `8fa633e0a044c8c3b194bffb4e71a915e24dafa0f97ca23f4420a5bd94e28932` |
| `model.safetensors` | 335,450,548 | `da813cf1a2c114807dfcf25736fd532bfa03c0481098a1b1d7898751d37875ec` |
| `model.safetensors.index.json` | 49,770 | `5ee67e4efeb75dfacb8dd3892dd6208473771264fdeff6b9eba4a79db5b1435e` |
| `tokenizer.json` | 11,422,650 | `be75606093db2094d7cd20f3c2f385c212750648bd6ea4fb2bf507a6a4c55506` |
| `tokenizer_config.json` | 728 | `5aa5069e1b0c0d623ce38e0df387e506b843e5c4d612a36d2e79e46a400e6450` |

### Prompt

Both sizes take the same input. The system message is `system.txt` and the user turn is the context lines, then `RAW: <transcript>`, one per line: `Vocabulary: a, b, c` (up to 100 terms, newlines turned to spaces, each cut to 60 characters), `Place: app <app>, title <window title>, page <url>` (only the parts present; newlines turned to spaces, `<` and `>` to `‹` and `›`, cut to 80, 160 and 120 characters), then `Before cursor: <field>…</field>` (the last 300 characters before the cursor, as is) and `After cursor: <field>…</field>` (the first 100 after it), both only when the field holds more than whitespace. `common.student_user` builds it. Render with the bundled chat template and `enable_thinking: false`, which ends the prompt with an empty think block (`<|im_start|>assistant\n<think>\n\n</think>\n\n`). Decode greedily and stop at the tokenizer's end-of-turn tokens: `<|im_end|>` or `<|endoftext|>` for 0.6B, `<|im_end|>` for 2B. `bench.py` and both apps cap output at max(160, 2.5 × RAW words + 80) tokens. Any `<think>…</think>` left in the output is stripped.
