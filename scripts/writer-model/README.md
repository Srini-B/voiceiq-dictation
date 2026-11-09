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

# 6. Custom writing rules and spelling variants. Haiku writes 95 users' settings (rule boxes, spelling) and
#    dictations for each; existing inputs are paired with them too. Sonnet labels each with that user's
#    production prompt, warming the cache once per user. filter.py also drops rows where the teacher kept
#    a word the spelling variant spells differently.
python gen_rules.py profiles --out data/rule_profiles.jsonl
python gen_rules.py inputs --profiles data/rule_profiles.jsonl --out data/inputs_rules.jsonl --pool data/mlx/all_filtered.jsonl
python label.py data/inputs_rules.jsonl --out data/labelled_rules.jsonl
python filter.py data/labelled_rules.jsonl --cases bench/cases.jsonl --cases bench/rules_cases.jsonl --out data/rules --test 120 --valid 60
# A second set for rules that rewrite a value (time, date, number, word): many users, a few rows each.
python gen_rules.py profiles --set format --prefix f --per-theme 14 --seed 41 --out data/rule_profiles_format.jsonl
python gen_rules.py inputs --set format --per-profile 6 --seed 41 --profiles data/rule_profiles_format.jsonl --out data/inputs_rules_format.jsonl
python label.py data/inputs_rules_format.jsonl --out data/labelled_rules_format.jsonl
python filter.py data/labelled_rules_format.jsonl --cases bench/cases.jsonl --cases bench/rules_cases.jsonl --out data/rules_format --test 40 --valid 20
# Rows filtered before the rules cases existed that overlap them; make_mix.py --drop leaves them out.
python holdout.py data/mlx/all_filtered.jsonl data/mlx_targeted/all_filtered.jsonl --cases bench/rules_cases.jsonl --out data/holdout_rules_cases.jsonl
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

The rules round trains both sizes again from their bases, on the earlier data plus `data/rules`:

```sh
python make_mix.py --out data/mix06r --train data/mlx --train data/rules --valid data/mlx --valid data/rules --drop data/holdout_rules_cases.jsonl
python make_mix.py --out data/mix2br --train data/mlx_targeted --train data/mlx:10000 --train data/rules --valid data/mlx --valid data/mlx_targeted --valid data/rules --drop data/holdout_rules_cases.jsonl
python trim_long.py data/mix06r --model Qwen/Qwen3-0.6B --max 1024
python trim_long.py data/mix2br --model Qwen/Qwen3.5-2B --max 1024
mlx_lm.lora --config train/qwen3-0_6b-rules.yaml
python train.py --config train/qwen3_5-2b-rules.yaml
# Top-up on the format set with replay, resuming each rules adapter (train/*-rules-r2.yaml).
python make_mix.py --out data/mix06rf --train data/rules_format --train data/rules:800 --train data/mlx:800 --valid data/rules_format --valid data/rules --valid data/mlx --drop data/holdout_rules_cases.jsonl
python make_mix.py --out data/mix2brf --train data/rules_format --train data/rules:800 --train data/mlx:600 --train data/mlx_targeted:200 --valid data/rules_format --valid data/rules --valid data/mlx --valid data/mlx_targeted --drop data/holdout_rules_cases.jsonl

# The rules benchmark: --student renders each case's rules and spelling with common.student_user.
cd bench && python bench.py ../q4/qwen3_5-2b --system ../system.txt --student --cases rules_cases.jsonl --out results/rules-q4-qwen3_5-2b.jsonl
python score.py --cases rules_cases.jsonl --detail results/rules-*.jsonl
cd .. && python eval_heldout.py q4/qwen3_5-2b --meta data/rules/test_meta.jsonl --out results/heldout-rules-q4-qwen3_5-2b.jsonl
```

## Files

- `common.py` rebuilds the production prompt from the Swift sources and holds the student prompt, the `ValidationGate` port and the banned-form checks.
- `system.txt` is the student's system prompt. The user turn is `RAW: <transcript>`, optionally preceded by `Spelling:`, `Rules:`, `Vocabulary:`, `Place:` and cursor lines (`common.student_user`; `LocalWriterPrompt.user` in the app matches it).
- `chunked_gdn.py` is a chunked, differentiable gated-delta rule for training Qwen3.5's linear-attention layers. `python chunked_gdn.py` checks it against mlx-lm's per-token reference, including nearly parallel keys.
- `cards/` holds the model and dataset cards.
- `bench/` is the 42-case held-out benchmark (`cases.py`) and the 41-case custom-rules benchmark (`rules_cases.py`). Their cases are never used as seeds or training data. `filter.py` drops any row that shares a 13-word sequence with a case or whose embedding is close to one, and `holdout.py` finds such rows in data filtered before a case set existed. `score.py` also fails an output that stopped at its token budget (mlx-lm `length`, llama-server `limit`), because the app inserts the transcript for it. The scores in the cards and `docs/WRITER_MODEL.md` use the checks as of `1e18473`; rescoring saved results needs no rerun, since `score.py` reads only the output text and `finish`.
