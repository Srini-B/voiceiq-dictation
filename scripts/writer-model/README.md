# VoiceIQ Writer pipeline

These scripts distil the production cloud cleanup (Claude Sonnet 5.5 with `PromptV1.cleanupPrompt`) into a small on-device model. See [docs/WRITER_MODEL.md](../../docs/WRITER_MODEL.md) for the design, results and app integration.

Large files never go into git. Inputs, teacher labels and training files are in the private Hugging Face dataset `cyron/voiceiq-writer-data`. The shipped model is the public `cyron/voiceiq-writer-qwen3_5-2b`.

## Data

Run the data steps from this directory with Python 3.11 or later and `ANTHROPIC_API_KEY` set. `gen_synthetic.py` and `label.py` append to their output files and skip finished work, so a rerun resumes. `assemble_public.py` and `filter.py` replace their output; give a run with another seed or scale its own `--out` to keep earlier records.

```sh
python -m venv .venv && . .venv/bin/activate && pip install -r requirements.txt

# 1. Public inputs (14,638). Only the raw transcripts are used.
python assemble_public.py --out data/inputs_public.jsonl

# 2. Synthetic inputs for the weak categories (10,944). Claude writes raw dictations only.
python gen_synthetic.py --out data/inputs_synthetic.jsonl

# 3. Teacher targets: Sonnet 5.5 with the exact production prompt, through the Batches API.
#    The pilot prints the measured cost per example and the projection for the rest.
python label.py data/inputs_public.jsonl data/inputs_synthetic.jsonl --out data/labelled.jsonl --sample 300
python label.py data/inputs_public.jsonl data/inputs_synthetic.jsonl --out data/labelled.jsonl

# 4. Filter (ValidationGate port, banned forms, overlap with the 42 benchmark cases) and split.
python filter.py data/labelled.jsonl --cases bench/cases.jsonl --out data/mlx

# 5. Second round for the rules the first model still broke: Haiku writes inputs, Sonnet labels them.
python gen_synthetic.py --set targeted --model claude-haiku-5-5 --seed 21 --out data/inputs_targeted.jsonl
python label.py data/inputs_targeted.jsonl --out data/labelled_targeted.jsonl
python filter.py data/labelled_targeted.jsonl --cases bench/cases.jsonl --out data/mlx_targeted --test 140 --valid 70
```

## Training and evaluation

Run these on Apple silicon with `mlx==0.32.4` and `mlx-lm==0.32.2`. Set `VOICEIQ_REPO` when the scripts run outside a checkout; `common.py` reads the prompt from the Swift sources under it.

```sh
# Drop the 11 training rows over 1,024 tokens, then build the shipped model's mix. The shipped 2B mix reused
# this Qwen3-0.6B trim; for a new run, trim with the tokenizer of the model it trains.
python trim_long.py data/mlx --model Qwen/Qwen3-0.6B --max 1024
python make_mix.py --out data/mix2b --train data/mlx_targeted --train data/mlx:10000 --valid data/mlx --valid data/mlx_targeted

# LoRA fine-tune. train.py is mlx_lm.lora with the chunked gated-delta path patched in (Qwen3.5 needs it in 16 GB).
python train.py --config train/qwen3_5-2b.yaml
mlx_lm.fuse --model Qwen/Qwen3.5-2B --adapter-path adapters/qwen3_5-2b --save-path fused/qwen3_5-2b
mlx_lm.convert --hf-path fused/qwen3_5-2b --mlx-path q4/qwen3_5-2b -q --q-bits 4 --q-group-size 64

# The 42-case benchmark with the student's short prompt, and the held-out teacher slices.
cd bench && python score.py --self-test
python bench.py ../q4/qwen3_5-2b --system ../system.txt --user-format 'RAW: {raw}' --cases cases.jsonl --out results/q4-qwen3_5-2b.jsonl
python score.py --detail results/*.jsonl > report.md
cd .. && python eval_heldout.py q4/qwen3_5-2b --meta data/mlx/test_meta.jsonl --out results/heldout-q4-qwen3_5-2b.jsonl
python eval_heldout.py q4/qwen3_5-2b --meta data/mlx_targeted/test_meta.jsonl --out results/heldout-targeted-q4-qwen3_5-2b.jsonl
```

The Qwen3-0.6B configs (`train/qwen3-0_6b.yaml`, then `train/qwen3-0_6b-r2.yaml`) run with `mlx_lm.lora` directly.

## Files

- `common.py` rebuilds the production prompt from the Swift sources and holds the student prompt, the `ValidationGate` port and the banned-form checks.
- `system.txt` is the student's system prompt. The user turn is `RAW: <transcript>`, optionally preceded by `Vocabulary:`, `Place:` and cursor lines.
- `chunked_gdn.py` is a chunked, differentiable gated-delta rule for training Qwen3.5's linear-attention layers. `python chunked_gdn.py` checks it against mlx-lm's per-token reference, including nearly parallel keys.
- `cards/` holds the model and dataset cards.
- `bench/` is the 42-case held-out benchmark. Its cases are never used as seeds or training data. `filter.py` drops any row that shares a 13-word sequence with a case or whose embedding is close to one.
