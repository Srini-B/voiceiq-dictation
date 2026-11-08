# VoiceIQ Writer: the on-device writing model

VoiceIQ Writer is a small English model that does the writing step offline: it turns a raw transcript into the text the speaker meant to type, as Claude Sonnet 5.5 does today with `PromptV1.cleanupPrompt`. It is not wired into the apps yet. This page covers how it is built, how it scores and how it would plug in.

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

## How it would plug in

The cloud cleanup stays the default. The model would be a third writing option next to the cloud providers, offered once it is downloaded, and installed like the Fluid Speech models: a `LocalModelManifest` pinned to a Hugging Face revision with file sizes and SHA-256 digests, downloaded anonymously from the public repo. The files at revision `0efe70d13ec7981acd39e36a537d2e628bd36dbb` (the README is not needed on device):

| File | Bytes | SHA-256 |
| --- | --- | --- |
| `chat_template.jinja` | 7,755 | `273d8e0e683b885071fb17e08d71e5f2a5ddfb5309756181681de4f5a1822d80` |
| `config.json` | 2,625 | `8893a91e9b7763d7b94c6db181f5b7c79c6f4881a69cefb11549eefcab1823bf` |
| `model.safetensors` | 1,059,404,951 | `a7111ba73a1c0b35e741d84258dd785daa1523260222a65ec72263fb280cf68c` |
| `model.safetensors.index.json` | 60,786 | `3b2dffa510d1d73decdbc12d5e1bc7d6a9f7b2deb631bfd84238a1f8fc4e0fd1` |
| `tokenizer.json` | 19,989,339 | `a5cd9732badce41de57e6efce8302930ded1c1188c5f81feb2bd6c24c4a1941f` |
| `tokenizer_config.json` | 1,501 | `86f01837a638275f2d3479804e79802aaff0e3ccef15e5f29dd6afbe6551daed` |

- **Mac.** Run the MLX 4-bit weights in-process with mlx-swift (`MLXLLM`). Peak memory is 1.24 GB, so it fits an 8 GB Mac next to Fluid Speech. The system prompt is static, so its KV cache is computed once at warm-up and reused, as `bench.py` measures. The output goes through `ValidationGate` and the same fallback to the raw transcript as the cloud path, so a bad output never reaches the cursor.
- **iPhone.** The writing step runs in the app's background voice session, and iOS does not allow Metal work in the background, so the model must run on the CPU. Two routes:
  - llama.cpp with a GGUF Q4_K_M export (about 1.2 GB for the 2B model), CPU only. Qwen3.5's gated-delta layers need a llama.cpp build with the Qwen3.5 architecture; measure CPU speed on an iPhone before committing to 2B.
  - Core ML on CPU with a converted model, following the Fluid Speech Pro conversion. That needs a stateful KV-cache export and is more work.
  If 2B is too slow on the iPhone CPU, Qwen3-0.6B round 1 (35/42 at 4-bit, 36/42 at bf16, 0.34 GB) is the fallback: standard attention and a third of the weights. Its 4-bit build is kept in the private repo `cyron/voiceiq-writer-qwen3-0_6b` (revision `b2cbc5c689c2719c1f1162255ca6cd47a4fd70c0`); it would have to be made public before an app could download it.
- **Prompt context.** Vocabulary, PLACE and the field text map onto the student's `Vocabulary:`, `Place:` and cursor lines. Custom writing rules and the spelling-variant line do not carry over: the student learned the default rules only. The question-answered retry has no reminder to send; on that rejection, insert the transcript.
