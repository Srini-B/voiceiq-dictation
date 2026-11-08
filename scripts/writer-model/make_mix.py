"""Combines filtered splits into one mlx-lm data folder.

  --train A:N  takes N rows of A/train.jsonl (all when N is omitted), sampled with --seed
  --valid A    appends A/valid.jsonl

usage: python make_mix.py --out data/mix --train data/mlx --train data/mlx_targeted --valid data/mlx --valid data/mlx_targeted
"""
import argparse
import random
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument("--out", required=True)
p.add_argument("--train", action="append", required=True)
p.add_argument("--valid", action="append", required=True)
p.add_argument("--seed", type=int, default=0)
args = p.parse_args()
rng = random.Random(args.seed)


def lines(folder, split):
    return Path(folder, f"{split}.jsonl").read_text().splitlines()


train = []
for spec in args.train:
    folder, _, n = spec.partition(":")
    rows = lines(folder, "train")
    train += rng.sample(rows, int(n)) if n else rows
rng.shuffle(train)
valid = [l for folder in args.valid for l in lines(folder, "valid")]
out = Path(args.out)
out.mkdir(parents=True, exist_ok=True)
(out / "train.jsonl").write_text("\n".join(train) + "\n")
(out / "valid.jsonl").write_text("\n".join(valid) + "\n")
print(f"train {len(train)} valid {len(valid)}")
