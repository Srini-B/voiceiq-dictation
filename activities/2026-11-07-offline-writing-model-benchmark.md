# 2026-11-07: Offline writing model benchmark (≤2B, MLX)

## Why

Transcription already runs on device. Cleanup still goes to Gemini, OpenAI or
Claude. The owner asked for an open model of about 2B parameters or less, English
only, that runs on an 8 GB Mac and on an iPhone and follows the writing rules. The
goal is to make the whole pipeline offline. This was research only, and no code
changed.

## Method

- Candidates came from the Hugging Face API, model cards, and the local cleanup
  setups of open-source dictation apps (VoiceInk, OpenWhispr, Phonon, Handy,
  FluidVoice).
- The prompt was rebuilt from `PromptV1.cleanupPrompt(raw:)` with no options:
  rules, `DefaultWritingRules`, examples and the layout reminder. That is
  36,048 characters, about 8k tokens. A compact variant dropped the
  `DefaultWritingRules` block.
- The test set had 42 held-out dictations that do not appear in the prompt's
  examples. They cover corrections, restatements, changes of mind, side notes,
  fillers, sentence boundaries, lists, emails, chat, numbers, money, sound-alikes,
  mishearings, questions, injection, clarifications, spoken punctuation, dashes,
  spelling, word order and long input.
- Each case had deterministic checks: required strings, banned strings and
  regexes. The production `ValidationGate` was ported to Python for the run.
  - Every reference output passed all 42 checks.
  - Inserting the raw transcript unchanged passed 9 of 42. That is the floor.
- The runner used mlx-lm 0.32.2 with greedy decoding. It prefilled the static
  prompt prefix once as a KV cache, then ran each case on top of it.
- Hardware: Mac mini M2, 16 GB RAM, macOS 27.2. Speed was measured again on a
  quiet machine, because Xcode builds overlapped with part of the run.
- Every download and the scratch folder were deleted afterwards.

## Results

| Model | Prompt | Passed | Peak GB | Quiet cached TTFT / cold TTFT |
|---|---|---|---|---|
| superwhisper/s1-mini (Qwen3-0.6B fine-tune) | its own | 26/42 | 1.32 | 0.06 s / 0.14 s |
| Gemma4-E2B-IT-Text-int4 | compact | 23/42 | 3.39 | 0.06 s / 3.3 s |
| Gemma4-E2B-IT-Text-int4 | production | 22/42 | 3.38 | 0.08 s / 4.9 s |
| Kayetic/super-cleanup-qwen3.5-2b | its own | 22/42 | 1.10 | 0.09 s / 0.32 s |
| Qwen3-1.7B-4bit | production | 20/42 | 2.45 | 0.26 s / 17.2 s |
| spokenly/cleanup-1 (Qwen3-0.6B-Base) | its own | 20/42 | 1.28 | 0.05 s / 0.09 s |
| Qwen3.5-2B-4bit | production | 18/42 | 2.46 | 0.16 s / 12.9 s |
| MiniCPM5-2B-4bit | production | 14/42 (7 gate rejects) | 2.40 | (noisy) |
| granite-4.0-h-1b, LFM2.5-1.2B, LFM3-1.7B | production | 0/42 | 1.6–4.2 | (noisy) |

- LFM2.5 summarised the prompt instead of cleaning the dictation. LFM3 pasted
  the prompt's examples into its output and started `<think>` blocks even with
  thinking turned off. Granite answered with "Here is the text…".
- No model added content or answered a dictated question.
- Every model missed most of the rules that matter most:
  - Lists from implicit requests, and nested lists.
  - Sound-alike fixes and mishearings that need context.
  - Word order.
  - Gemma also missed the number and money rules, and left correction markers
    such as "make that Friday" in place.

## Decision

No model of 2B or less can replace the cloud writing model with the production
prompt today. Speed and memory are not the problem: with a cached prefix every
model starts in under 0.3 s and fits in 8 GB. Rule-following quality is the
gap. The realistic path is to fine-tune (distil) a small model on the current
cloud pipeline's outputs, using a short prompt. Qwen3.5-2B and Qwen3-0.6B are
the bases that dictation apps already use for this. The Gemma 4 E2B text model
is the strongest general model here.

Licences:
- LFM models: commercial use only under $10M annual revenue.
- s1-mini: requires attribution to Superwhisper.
- Gemma 4, Qwen3, Qwen3.5 and super-cleanup: Apache 2.0.

Benchmark threads: research in
https://ampcode.com/threads/T-9578c0dc-030c-4f2a-82e9-4c167e31a175, runs in
https://ampcode.com/threads/T-01a1b4c2-c808-7384-b62e-6cafe5780460.
