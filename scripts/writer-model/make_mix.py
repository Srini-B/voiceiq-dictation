"""Combines filtered splits into one mlx-lm data folder.

  --train A:N  takes N rows of A/train.jsonl (all when N is omitted), sampled with --seed
  --valid A    appends A/valid.jsonl
  --drop F     leaves out train rows whose target is a "target" in F (holdout.py's output)

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
p.add_argument("--drop", action="append", default=[])
p.add_argument("--seed", type=int, default=0)
args = p.parse_args()
rng = random.Random(args.seed)
drop = {json.loads(l)["target"] for f in args.drop for l in Path(f).read_text().splitlines() if l.strip()}


def lines(folder, split):
    return Path(folder, f"{split}.jsonl").read_text().splitlines()


def raw(line):
    """The RAW transcript of a common.student_user turn, without its context lines.
    Rules and field context are free text; the other lines are single-line, so
    RAW starts at the first line that begins with "RAW: " after the last of them."""
    user = next(m["content"] for m in json.loads(line)["messages"] if m["role"] == "user")
    if "</field>\nRAW: " in user:
        return user.rpartition("</field>\nRAW: ")[2]
    if user.startswith(("Rules: <rules>", "Spelling: ")) and "</rules>\n" in user:
        user = user.partition("</rules>\n")[2]
    return ("\n" + user).partition("\nRAW: ")[2]


# filter.py splits each corpus on its own, so a RAW in one corpus's valid or
# test slice can sit in another's train split, with or without context lines.
folders = {spec.partition(":")[0] for spec in args.train} | set(args.valid)
held = {raw(l) for folder in folders for split in ("valid", "test")
        if Path(folder, f"{split}.jsonl").exists() for l in lines(folder, split)}
train, dropped = [], 0
for spec in args.train:
    folder, _, n = spec.partition(":")
    rows = lines(folder, "train")
    keep = [l for l in rows if raw(l) not in held and json.loads(l)["messages"][-1]["content"] not in drop]
    dropped += len(rows) - len(keep)
    rows = keep
    train += rng.sample(rows, int(n)) if n else rows
rng.shuffle(train)
valid = [l for folder in args.valid for l in lines(folder, "valid")]
out = Path(args.out)
out.mkdir(parents=True, exist_ok=True)
(out / "train.jsonl").write_text("\n".join(train) + "\n")
(out / "valid.jsonl").write_text("\n".join(valid) + "\n")
print(f"train {len(train)} valid {len(valid)} (dropped {dropped} held-out train rows)")
