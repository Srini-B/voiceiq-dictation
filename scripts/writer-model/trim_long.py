"""Drops training rows longer than --max tokens after the chat template, so a
batch of the longest rows fits in memory without gradient checkpointing.
Keeps the original as train_full.jsonl. Valid and test stay whole.

usage: python trim_long.py data/mlx --model Qwen/Qwen3-0.6B --max 1024
"""
import argparse
import json
from pathlib import Path

from transformers import AutoTokenizer

p = argparse.ArgumentParser()
p.add_argument("data")
p.add_argument("--model", required=True)
p.add_argument("--max", type=int, default=1024)
args = p.parse_args()

tok = AutoTokenizer.from_pretrained(args.model)
d = Path(args.data)
full = d / "train_full.jsonl"
if not full.exists():
    (d / "train.jsonl").rename(full)
rows = [json.loads(l) for l in open(full)]
def length(msgs):
    text = tok.apply_chat_template(msgs, tokenize=False, enable_thinking=False)
    return len(tok(text, add_special_tokens=False)["input_ids"])


keep = [r for r in rows if length(r["messages"]) <= args.max]
with open(d / "train.jsonl", "w") as f:
    for r in keep:
        f.write(json.dumps(r, ensure_ascii=False) + "\n")
print(f"kept {len(keep)} of {len(rows)} (dropped {len(rows) - len(keep)} over {args.max} tokens)")
