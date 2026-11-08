"""Scores a student model against the teacher on the held-out test slice
(data/mlx/test_meta.jsonl): ValidationGate verdicts, banned forms, exact match
and character similarity to Sonnet's target, per category. Runs with MLX.

usage: python eval_heldout.py MODEL [--adapter ADAPTER_DIR] --meta data/mlx/test_meta.jsonl --out results/heldout-NAME.jsonl
"""
import argparse
import difflib
import json
import re
import time
from collections import defaultdict
from pathlib import Path

from mlx_lm import generate, load
from mlx_lm.sample_utils import make_sampler

from common import banned_forms, gate, read_jsonl, strip_artifacts, student_messages

p = argparse.ArgumentParser()
p.add_argument("model")
p.add_argument("--adapter", default=None)
p.add_argument("--meta", required=True)
p.add_argument("--out", required=True)
p.add_argument("--limit", type=int, default=0)
args = p.parse_args()

model, tok = load(args.model, adapter_path=args.adapter)
rows = read_jsonl(args.meta)[: args.limit or None]
sampler = make_sampler(temp=0.0)


def norm(s):
    return re.sub(r"\s+", " ", s).strip()


per_cat = defaultdict(lambda: dict(n=0, gate_ok=0, exact=0, sim=0.0, banned=0))
tot = dict(n=0, gate_ok=0, exact=0, sim=0.0, banned=0)
t0 = time.time()
Path(args.out).parent.mkdir(parents=True, exist_ok=True)
with open(args.out, "w") as f:
    for r in rows:
        prompt = tok.apply_chat_template(student_messages(r), add_generation_prompt=True, tokenize=False,
                                         enable_thinking=False)
        out = generate(model, tok, prompt, max_tokens=max(160, int(len(r["raw"].split()) * 2.5) + 80),
                       sampler=sampler)
        out = strip_artifacts(re.sub(r"<think>.*?</think>", "", out, flags=re.S))
        g = gate(r["raw"], out)
        b = banned_forms(r["raw"], out)
        sim = difflib.SequenceMatcher(None, out, r["target"]).ratio()
        exact = norm(out) == norm(r["target"])
        for d in (per_cat[r["category"]], tot):
            d["n"] += 1
            d["gate_ok"] += g == "ok"
            d["exact"] += exact
            d["sim"] += sim
            d["banned"] += bool(b)
        f.write(json.dumps(dict(id=r["id"], category=r["category"], raw=r["raw"], target=r["target"], output=out,
                                gate=g, banned=b, sim=round(sim, 3), exact=exact), ensure_ascii=False) + "\n")


def fmt(d):
    n = max(d["n"], 1)
    return f"{d['n']} | {d['gate_ok']}/{d['n']} | {d['banned']} | {d['exact'] / n:.0%} | {d['sim'] / n:.3f}"


print(f"model {args.model} adapter {args.adapter} ({time.time() - t0:.0f}s)")
print("| Category | N | Gate ok | Banned | Exact | Similarity |\n|---|---|---|---|---|---|")
for c in sorted(per_cat):
    print(f"| {c} | {fmt(per_cat[c])} |")
print(f"| **all** | {fmt(tot)} |")
