# 2026-11-07 to 2026-11-08: VoiceIQ Writer, an on-device writing model

## Why

The owner wants the writing step offline. Transcription already runs on device, but the cleanup still calls Claude Sonnet 5.5 with the long `PromptV1` rules prompt. The 2026-11-07 benchmark found no off-the-shelf small model good enough: the best, superwhisper/s1-mini, passed 26 of 42 held-out cases, and untuned Qwen3.5-2B passed 18. The plan was to distil the production cleanup into a model of 2B parameters or less that runs on an 8 GB Mac and on an iPhone.

## Outcome

- `cyron/voiceiq-writer-qwen3_5-2b` (public, MLX 4-bit, 1.06 GB of weights) passes 40/42 with no answered or injected output. Median total 0.33 s and cached time to first token 0.10 s on an M2; peak memory 1.24 GB. See [docs/WRITER_MODEL.md](../docs/WRITER_MODEL.md).
- Repository revision: `0efe70d13ec7981acd39e36a537d2e628bd36dbb`. The smaller `cyron/voiceiq-writer-qwen3-0_6b` (35/42, 0.34 GB) is public too, at `2c328e68fc4c6e902682304a34263aeb3c23bbdd`, so the iPhone can offer both sizes. Private dataset `cyron/voiceiq-writer-data` at `863d219161bfc2e5fe8c8d3823d067743519c488` (data, cards and evaluation results under `eval/`).
- The model is not wired into the apps yet. The docs describe how it would plug in.

## Decisions

- **Teacher and inputs.** Targets come from Sonnet 5.5 with the exact production prompt, rebuilt from the Swift sources, so they match what users get today. Public datasets supply inputs only; their own cleaned outputs break VoiceIQ's rules.
- **Labelling through the Batches API.** A 300-target pilot measured $0.00212 per target, so the full set of 25.5k was projected at $54 against the $250 limit. The final cost was $0.00198 per target.
- **Overlap filter.** At the first threshold (cosine 0.80) the filter caught only exact repeats of a benchmark question, which the synthetic brief had used as an example. The threshold went to 0.65, which drops 69 near neighbours, and the example in the brief was replaced.
- **Banned forms.** The first subject-line and preamble rules dropped targets where the speaker had dictated "subject ..." or opened with "I can't". They now allow forms the speaker said.
- **Short system prompt.** The student sees 25 tokens of system prompt and `RAW: <transcript>`, so the 8k-token rules prompt is not needed on device.
- **Qwen3.5 training on 16 GB.** mlx-lm's per-token gated-delta training path ran out of memory at batch 1, so we wrote `chunked_gdn.py`. Its first version used a nilpotent power series for the intra-chunk inverse, which is exact on paper but went NaN on real activations; the Mac worker found it and replaced it with blocked inversion before any 2B result was used.
- **Gradient checkpointing on.** Without it, Qwen3-0.6B at 4×1024 tokens peaked at 16.8 GB and swapped. The 11 training rows over 1,024 tokens were dropped instead of truncated.
- **Second round.** Qwen3-0.6B reached 36/42 at bf16 but 35/42 at 4-bit. Its failures guided 3,516 new inputs for seven rules, written by Haiku 5.5 to save credit. On 0.6B the round fixed two cases and broke two others, and general similarity fell. The 2B run therefore mixed the targeted rows into 10k main rows.
- **2B base.** A 200-step A/B picked raw Qwen3.5-2B over Kayetic's super-cleanup fine-tune (4-bit only, 55k vocabulary): 0.078 against 0.085 validation nats per character.
- **Hosting.** The owner made the model repo public so the apps can download it anonymously; the dataset stays private. The owner accepted the Anthropic-terms and share-alike risk. The model card lists every source with its licence and attribution.
- **Compute.** HF Jobs refused with 402 (no pre-paid credit), so everything ran on the shared Mac mini.

## Costs

- Anthropic: about $82.90 of the $100 credit. Teacher targets $55.56, synthetic inputs $27.03, checks about $0.30.
- Hugging Face GPU: $0.
- Mac mini time: about 12 hours of training, plus evaluation.

## Verification

- `score.py --self-test`: all 42 references pass the checks and the gate.
- `python chunked_gdn.py`: outputs, final state and gradients match mlx-lm's per-token reference within about 1e-5 (the `a` gradient within 4.3e-5), including a nearly-parallel-keys case. Training loss matches the Metal kernel within 0.5% on real batches.
- The production prompt rebuilt by `common.py` equals the benchmark's `prompt_prefix.txt` byte for byte, and the teacher request's system and user blocks join back into `PromptV1.cleanupPrompt`.
- The published repo, downloaded anonymously into a fresh cache, scores 40/42 on the bench, with outputs byte-identical to the local 4-bit run.

## Cleanup

All downloaded base models, fused weights, adapters and data were deleted from the Mac mini scratch folder and from the orb. Only the Hugging Face repos remain.

## Open risks

- Anthropic's commercial terms restrict training competing models on outputs, and whether CC BY-SA share-alike reaches a model trained on inputs is unsettled. The owner accepted both for the public release; legal has not reviewed them.
- iPhone speed is unmeasured. A Qwen3.5 GGUF needs llama.cpp support for its gated-delta layers, and 2B on the CPU may be slow in the background session.
- The student does not know custom writing rules or the spelling variant.
