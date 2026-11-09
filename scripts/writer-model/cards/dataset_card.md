---
license: other
language:
- en
pretty_name: VoiceIQ Writer training data
tags:
- dictation
- transcript-cleanup
- distillation
---

# VoiceIQ Writer training data (private)

This dataset distils VoiceIQ's cloud writing step into a small on-device model. Each row pairs a raw speech-recognizer transcript with the text VoiceIQ's production cleanup writes for it: Claude Sonnet 5.5 (`claude-sonnet-5-5`) with the app's `PromptV1.cleanupPrompt` prompt, unchanged.

The pipeline lives in the VoiceIQ repository under `scripts/writer-model/`.

## Files

| File | Rows | Contents |
| --- | --- | --- |
| `inputs_public.jsonl` | 14,638 | Raw dictations sampled from public datasets (inputs only) |
| `inputs_synthetic.jsonl` | 10,944 | Raw dictations written by Claude Sonnet 5.5 for weak categories |
| `labelled.jsonl` | 25,500 | Inputs with the teacher target, stop reason and token usage |
| `mlx/train.jsonl`, `mlx/valid.jsonl`, `mlx/test.jsonl` | 24,116 / 400 / 600 | Filtered rows in mlx-lm chat format with the student's short system prompt |
| `mlx/test_meta.jsonl` | 600 | The held-out test slice with its source, category and teacher target |
| `mlx/all_filtered.jsonl` | 25,116 | Every kept row with its split |
| `mlx/stats.json` | | Drop counts by reason, rows by source, nearest rows to the benchmark |
| `inputs_targeted.jsonl`, `labelled_targeted.jsonl` | 3,516 | Second round: raw dictations for the rules the first model still broke, written by Claude Haiku 5.5, with Sonnet 5.5 targets |
| `mlx_targeted/` | 3,262 / 70 / 140 | The second round filtered and split the same way |
| `mix2b/train.jsonl`, `mix2b/valid.jsonl` | 13,262 / 470 | The exact training data of `cyron/voiceiq-writer-qwen3_5-2b` at revision `0efe70d`: all of `mlx_targeted/train.jsonl` and 10,000 rows of `mlx/train.jsonl` (after dropping 11 rows over 1,024 tokens), from `make_mix.py --seed 0` |
| `rule_profiles.jsonl` | 95 | Custom-rules round: synthetic users' settings (custom rules text and/or English spelling variant), written by Claude Haiku 5.5 (`gen_rules.py profiles`) |
| `inputs_rules.jsonl`, `labelled_rules.jsonl` | 3,441 | Dictations for those users (Haiku-written, plus existing inputs under each user's settings), with Sonnet 5.5 targets from the production prompt carrying that user's rules and spelling line; `labelled_rules.warm.jsonl` logs the per-user cache warm-up calls |
| `rules/` | 3,104 / 60 / 120 | The custom-rules rows filtered and split; `test_meta.jsonl` keeps each row's `rules` and `spelling` |
| `rule_profiles_format.jsonl`, `inputs_rules_format.jsonl`, `labelled_rules_format.jsonl`, `rules_format/` | 84; 502; 422 / 20 / 40 | A second custom-rules set for rules that rewrite a value (time, date, number, word). Used only for a top-up that was not shipped, and as a held-out slice |
| `holdout_rules_cases.jsonl` | 46 | Rows of `mlx/` and `mlx_targeted/` that overlap the custom-rules benchmark; `make_mix.py --drop` leaves them out |
| `teacher_rules_cases.jsonl` | 43 | The teacher's own outputs on the custom-rules benchmark (the 41 current cases and 2 that were replaced) |
| `mix2br/`, `mix06r/` | 16,356 / 530; 27,104 / 460 | The exact training data of the custom-rules revisions of the 2B and the 0.6B (`make_mix.py --seed 0 --drop holdout_rules_cases.jsonl`, then `trim_long.py` with each model's tokenizer); `train_full.jsonl` is before trimming |
| `eval/rules-round/` | | Benchmark outputs, held-out results and training logs of the custom-rules round, including the unshipped top-up |

## Filtering

- The ported `ValidationGate` must accept the teacher target. It rejects answers, expansion, shrinkage and divergence.
- Targets with banned forms are dropped: em or en dashes, preambles, labels, tag or prompt leaks, and headings or subject lines the speaker did not dictate.
- Rows that overlap the 42 held-out benchmark cases, or (from the custom-rules round) the 41 custom-rules cases, are dropped: a shared 13-word sequence in RAW or target, or MiniLM-L6 cosine similarity of 0.65 or more to a case's RAW.
- With a spelling variant set, targets that keep a word the variant spells differently are dropped (the teacher ignores the spelling line about half the time).
- Exact duplicate RAWs are dropped.

## Sources and licences

The public datasets supply raw inputs only. Their own cleaned outputs are never used. Every target was written by the teacher.

| Source | Licence | Rows kept | Attribution |
| --- | --- | --- | --- |
| [ductai199x/dictation-to-text](https://huggingface.co/datasets/ductai199x/dictation-to-text) | CC BY-SA 4.0 (rows carry CC BY-SA 2.5/3.0/4.0, CC0 or public-domain source text) | 4,477 | ductai199x; per-row `source_url` kept in `inputs_public.jsonl` |
| [shantanugoel/aawaaz-transcript-cleanup-dataset](https://huggingface.co/datasets/shantanugoel/aawaaz-transcript-cleanup-dataset) | MIT | 2,487 | Shantanu Goel |
| [mohitkrconnect/heed-voice-notes-to-tasks](https://huggingface.co/datasets/mohitkrconnect/heed-voice-notes-to-tasks) | CC BY 4.0 | 1,991 | mohitkrconnect |
| [nyralabs/disfluency_speech_english](https://huggingface.co/datasets/nyralabs/disfluency_speech_english) | Apache-2.0 | 1,070 | Nyra Labs; DisfluencySpeech, Wang and Herremans (2024), arXiv:2406.08820 |
| [tasksource/slurp](https://huggingface.co/datasets/tasksource/slurp) | CC BY 4.0 | 996 | SLURP, Bastianelli et al. (2020); repackaged by tasksource |
| [google-research-datasets/disfl_qa](https://huggingface.co/datasets/google-research-datasets/disfl_qa) | CC BY 4.0 (questions derive from SQuAD 2.0, CC BY-SA 4.0) | 781 | Gupta et al. (2021), Disfl-QA |
| [juanquivilla/sotto-transcript-cleanup](https://huggingface.co/datasets/juanquivilla/sotto-transcript-cleanup) | MIT | 794 | juanquivilla |
| [hey-lemon/streaming-dictation-asr](https://huggingface.co/datasets/hey-lemon/streaming-dictation-asr) | CC BY 4.0 (in-house rows only) | 531 | Mansoor, Wisal, Bhatti and Shakir (2026), "Beyond Word Error Rate" |
| [ylacombe/podcast_fillers_processed](https://huggingface.co/datasets/ylacombe/podcast_fillers_processed) (CC BY 3.0 subset) | CC BY 3.0 | 598 | PodcastFillers podcasts (Zhu et al., 2022), processed by ylacombe |
| [JacobLinCool/ami-disfluent](https://huggingface.co/datasets/JacobLinCool/ami-disfluent) | CC BY 4.0 | 493 | AMI Meeting Corpus (Carletta et al., 2005); processed by JacobLinCool |
| [deepset/prompt-injections](https://huggingface.co/datasets/deepset/prompt-injections) | Apache-2.0 | 132 | deepset |
| Synthetic inputs | Generated by Claude Sonnet 5.5 | 10,766 | |
| Synthetic inputs, second round | Generated by Claude Haiku 5.5 | 3,472 | |
| Synthetic users' rules and dictations, custom-rules round | Generated by Claude Haiku 5.5 | 2,672 and 482 (format set) | |

Targets were generated with Anthropic's API; check Anthropic's commercial terms before reuse.
