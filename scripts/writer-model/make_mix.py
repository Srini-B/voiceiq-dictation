"""Combines filtered splits into one mlx-lm data folder.

  --train A:N  takes N rows of A/train.jsonl (all when N is omitted), sampled with --seed
  --valid A    appends A/valid.jsonl

usage: python make_mix.py --out data/mix --train data/mlx --train data/mlx_targeted --valid data/mlx --valid data/mlx_targeted
"""
import argparse
import json
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


def raw(line):
    return next(m["content"] for m in json.loads(line)["messages"] if m["role"] == "user")


# filter.py splits each corpus on its own, so a RAW in one corpus's valid or
# test slice can sit in another's train split.
folders = {spec.partition(":")[0] for spec in args.train} | set(args.valid)
held = {raw(l) for folder in folders for split in ("valid", "test")
        if Path(folder, f"{split}.jsonl").exists() for l in lines(folder, split)}
train = []
for spec in args.train:
    folder, _, n = spec.partition(":")
    rows = [l for l in lines(folder, "train") if raw(l) not in held]
    train += rng.sample(rows, int(n)) if n else rows
rng.shuffle(train)
valid = [l for folder in args.valid for l in lines(folder, "valid")]
out = Path(args.out)
out.mkdir(parents=True, exist_ok=True)
(out / "train.jsonl").write_text("\n".join(train) + "\n")
(out / "valid.jsonl").write_text("\n".join(valid) + "\n")
print(f"train {len(train)} valid {len(valid)}")
