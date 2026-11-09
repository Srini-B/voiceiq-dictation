# 2026-11-08 to 2026-11-09: VoiceIQ Writer follows custom rules and spelling

## Why

The cloud cleanup follows each user's custom writing rules and spelling variant. VoiceIQ Writer learned the default rules only, and the settings footer told users their own rules applied only when the provider wrote. The owner wanted that gap closed for both sizes.

## Outcome

- New public revisions: `cyron/voiceiq-writer-qwen3_5-2b` at `f9e2204333dfcd43432e983f8cd3f221150f72c9` and `cyron/voiceiq-writer-qwen3-0_6b` at `ad95a957445c6dcfd9bd515dda4f73140e64924b`. Each holds the MLX 4-bit files and the Q4_1 GGUF. The earlier revisions stay reachable.
- Private dataset `cyron/voiceiq-writer-data` is at `03f4e151cf5a985b4db66c8bdf25db2cf5b9d461`. The rules data, both training mixes and the round's evaluation results are under `eval/rules-round/`.
- On the new 41-case custom-rules benchmark, the 2B scores 33/41, up from 20/41. The 0.6B scores 26/41, also up from 20/41.
- On the 42-case benchmark, the 2B scores 38/42 (previously 39) and the 0.6B 36/42 (previously 34), with no answered or injected output. These use the checks as of `1e18473`; see "Rescore on the tightened bench" below.
- The student prompt gains optional `Spelling:` and `Rules: <rules>…</rules>` lines before the context lines. With neither, it is unchanged.
- The apps send both lines to the new revisions. The footer saying they apply only in the cloud is gone.
- See [docs/WRITER_MODEL.md](../docs/WRITER_MODEL.md).

## Decisions

- **Rules as a user-turn line, first.** The rules and spelling change least of the context lines, so they lead the user turn. That keeps them in an on-device prompt cache. It also keeps the old prompt byte-for-byte when they are absent, so a default-rules revision kept on disk sees what it learned. The Swift and Python builders were checked against each other on 5 vectors (`swiftc`), including CRLF rules, emoji and a 1,300-character box cut to 1,200.
- **The teacher's spelling gap.** On the 9 spelling cases, Sonnet with the production prompt keeps American spelling in 5. In the labels it did so in about half the rows with a word to change. `filter.py` drops those rows (128) instead of teaching the student the miss. The cloud prompt's spelling line may deserve its own look.
- **Benchmark independence.** One case first tested "client library" under a "customers, not clients" rule, a phrase the Haiku brief also used as an example. It was replaced by "email client" before training. 46 older training rows that overlap the new cases are dropped from the new mixes (`holdout.py`, `make_mix.py --drop`).
- **Both sizes retrained from their bases** on the earlier data plus 3,104 custom-rules rows, so default behaviour keeps its full weight.
- **No top-up.** The 0.6B changed values when it applied a date or time format, and the 24-hour and date rules came from only 2 and 7 users. A second set of 84 users with value-rewriting rules (482 rows) and a 505-step top-up were tried. Neither top-up met the acceptance rule. The 2B fell to 36/42 and broke the DD/MM date. The 0.6B lost 0.021 of general similarity. The rules-round models shipped, and the 0.6B card says to use the 2B for value-format rules.
- **Old revisions stay usable.** The manifests list the earlier revisions in `previousRevisions`, so a device keeps writing until it installs the update. `runLocalCleanup` sends the rules and spelling lines only to the pinned revision.

## Verification

- `score.py --self-test`: 42/42 and 41/41 references pass.
- Anonymous download of both repos at the new revisions:
  - Every file's size and SHA-256 match the app manifest.
  - MLX: 2B 39/42 and 33/41; 0.6B 37/42 and 26/41 (with the checks of the time; 38/42 and 36/42 after the rescore).
  - GGUF through llama-server on CPU: 2B 39/42 and 31/41; 0.6B 37/42 and 26/41 (38/42 and 36/42 after the rescore).
  - All 166 outputs per size are byte-identical to the pre-upload runs, and llama.cpp tokenizes every prompt as the Hugging Face tokenizer does.
- Held-out slices, similarity to Sonnet:
  - 600 general rows: 2B 0.886 (previously 0.874), 0.6B 0.867 (previously 0.871).
  - 120 custom-rules rows: 0.935 and 0.936.
  - No gate rejection is an answered or injected output.
- Cost: about $15.51 of Anthropic API, $0.51 over the $15 cap. The format set's labels cost $4.52 against a $3.2 projection, because of fewer cache hits and longer outputs. No cloud GPU was used.
- All downloads and intermediates were deleted on the Mac mini (30 GB) and in the orb.

## Rescore on the tightened bench (2026-11-09)

CodeRabbit and the owner found loose checks, so `9c8c503`, `607b800` and `1e18473` tightened `corr_dependent`, `spelled`, `technical_ids`, `dash_lists`, `checkbox_todos` and `no_contractions`, and `score.py` now fails an output stopped at its token budget. Every saved result was rescored without rerunning the models. The default-rules GGUFs' 42-case files had been lost from the Mac's `/tmp`, so `683b586` and `4dafcd4` were downloaded anonymously, rerun with `bench_llama.py` (0 prompt mismatches) and deleted.

| Variant | 42 cases, before → after | Rules cases (unchanged) |
| --- | --- | --- |
| 2B shipped `f9e2204`, MLX and GGUF | 39 → 38 | 33/41 MLX, 31/41 GGUF |
| 2B previous MLX `0efe70d` / GGUF `683b586` | 40 → 39 | 20/41 / 19/41 |
| 0.6B shipped `ad95a95`, MLX and GGUF | 37 → 36 | 26/41 |
| 0.6B previous MLX `2c328e6` / GGUF `4dafcd4` | 35 → 34 | 20/41 / 21/41 |
| 2B r2 (unshipped), MLX / GGUF | 36 → 35 | 33/41 / 32/41 |
| 0.6B r2 (unshipped), MLX / GGUF | 34 → 33, 33 → 32 | 36/41 / 37/41 |
| Teacher, Sonnet 5.5 | | 36/41 |

- Each fine-tune lost `technical_ids`: it writes "get user by id" and "fetch user" as spoken words. The r2 2B wrote `getUserById` but dropped fetchUser. The r2 0.6B lost `spelled` instead ("Jordan9").
- No other check flipped, no saved output hit its token budget, and there are 0 gate rejects.
- This round's bars were at least 39/42 for the 2B and 34/42 for the 0.6B. The 0.6B still clears its bar at 36/42; the 2B now misses its bar by one case at 38/42. The bars were left for the owner to decide.
- s1-mini (26/42) and untuned Qwen3.5-2B (18/42) keep their earlier scores, because their outputs were deleted on 2026-11-07.
- `1e18473` also gives the teacher the student's rules (normalised, first 1,200 code points). None of the 2,789 rule-bearing training rows in `mix2br` or `mix06r` exceeds 1,200 code points; the longest rules text in the dataset is 839. So no label follows a rule beyond the cut.
- `train/*-rules-r2.yaml` now holds the values that ran: 505 iterations (one epoch of 2,022 rows) and cosine decay `[1.0e-4, 126, 1.0e-5]`.
- Both model cards got README-only commits; the weights and the app manifests' pins did not change.

## Rollback

Point `LocalWriterManifest.swift` back at `0efe70d13ec7981acd39e36a537d2e628bd36dbb` (2B MLX), `683b58638ad4ace63de63b28ca716690dbf42a00` (2B GGUF) and `4dafcd49fed095730bffb162aeba3482a1c14b8e` (0.6B GGUF), with their earlier hashes, and pass no `spelling` or `rules` in `runLocalCleanup`.
