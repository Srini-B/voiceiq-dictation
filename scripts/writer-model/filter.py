"""Filters teacher-labelled rows and writes the MLX training data.

Drops a row when the teacher failed or was cut off, when the ported
ValidationGate rejects its target, when the target has a banned form (dashes,
preambles, labels, prompt leaks), when a spelling variant was set and the
target keeps a word the variant spells differently, or when the row overlaps
the held-out benchmark cases (a shared 13-word sequence, or embedding
similarity above --sim). Then splits train/valid/test and writes mlx-lm chat
jsonl.

usage: python filter.py data/labelled.jsonl --cases bench/cases.jsonl [--cases bench/rules_cases.jsonl] --out data/mlx [--test 600 --valid 400]
"""
import argparse
import hashlib
import json
import re
from collections import Counter, defaultdict
from pathlib import Path

import numpy as np

from common import banned_forms, gate, read_jsonl, spelling_misses, strip_artifacts, student_messages, write_jsonl

p = argparse.ArgumentParser()
p.add_argument("labelled", nargs="+")
p.add_argument("--cases", action="append", required=True, help="benchmark cases to hold out; repeatable")
p.add_argument("--out", required=True)
p.add_argument("--test", type=int, default=600)
p.add_argument("--valid", type=int, default=400)
p.add_argument("--sim", type=float, default=0.65, help="cosine threshold against benchmark raws")
p.add_argument("--embed-model", default="sentence-transformers/all-MiniLM-L6-v2")
args = p.parse_args()

rows = {}
for path in args.labelled:
    for r in read_jsonl(path):
        rows[r["id"]] = r
rows = list(rows.values())
cases = [c for path in args.cases for c in read_jsonl(path)]
drops = Counter()
kept = []
for r in rows:
    if not r.get("target") or r.get("stop_reason") != "end_turn":
        drops[f"teacher_{r.get('stop_reason')}"] += 1
        continue
    t = strip_artifacts(r["target"])
    g = gate(r["raw"], t)
    if g != "ok":
        drops[f"gate_{g.split('_')[0] if g[0] in 'es' else g}"] += 1
        continue
    b = banned_forms(r["raw"], t)
    if b:
        drops[f"banned_{b[0]}"] += 1
        continue
    # The teacher often leaves the recognizer's spelling under a spelling
    # variant; the student learns only rows where it switched every word.
    if spelling_misses(r["raw"], t, r.get("spelling")):
        drops["spelling_ignored"] += 1
        continue
    r["target"] = t
    kept.append(r)

# Overlap with the benchmark: 13-word shingles of RAW and target against each
# case's RAW and reference, then embedding similarity of RAW against case RAWs.
def toks(s):
    return re.findall(r"[a-z0-9']+", s.lower())


def shingles(s, n=13):
    w = toks(s)
    return {" ".join(w[i:i + n]) for i in range(len(w) - n + 1)}


bench = set()
for c in cases:
    bench |= shingles(c["raw"]) | shingles(c["reference"])
before = len(kept)
kept = [r for r in kept if not ((shingles(r["raw"]) | shingles(r["target"])) & bench)]
drops["overlap_13gram"] = before - len(kept)

from sentence_transformers import SentenceTransformer
emb = SentenceTransformer(args.embed_model, device="cpu")
cv = emb.encode([c["raw"] for c in cases], normalize_embeddings=True, batch_size=64)

raws = [r["raw"] for r in kept]
cache = Path(args.out) / f"emb-{hashlib.sha1(json.dumps([args.embed_model] + raws).encode()).hexdigest()[:12]}.npy"
if cache.exists():
    rv = np.load(cache)
else:
    rv = emb.encode(raws, normalize_embeddings=True, batch_size=64, show_progress_bar=True)
    cache.parent.mkdir(parents=True, exist_ok=True)
    np.save(cache, rv)
if kept:
    sims = rv @ cv.T
    best = sims.max(axis=1)
    near = sorted(((float(best[i]), kept[i]["raw"], cases[int(sims[i].argmax())]["id"]) for i in range(len(kept))),
                  reverse=True)[:15]
    kept2 = [r for i, r in enumerate(kept) if best[i] < args.sim]
else:
    near, kept2 = [], []
drops["overlap_embedding"] = len(kept) - len(kept2)
kept = kept2

# Exact duplicates of RAW (same text from two sources) keep the first.
seen, uniq = set(), []
for r in kept:
    k = re.sub(r"\W+", " ", r["raw"].lower()).strip()
    if k in seen:
        drops["duplicate_raw"] += 1
        continue
    seen.add(k)
    uniq.append(r)
kept = uniq

# Deterministic split by id hash, stratified by category for the test slice.
kept.sort(key=lambda r: hashlib.sha1(r["id"].encode()).hexdigest())
by_cat = defaultdict(list)
for r in kept:
    by_cat[r["category"]].append(r)
test, valid = [], []
cats = sorted(by_cat)
while len(test) < args.test and any(by_cat.values()):
    for c in cats:
        if by_cat[c] and len(test) < args.test:
            test.append(by_cat[c].pop())
rest = [r for c in cats for r in by_cat[c]]
rest.sort(key=lambda r: hashlib.sha1(r["id"].encode()).hexdigest())
valid, train = rest[: args.valid], rest[args.valid:]

out = Path(args.out)
# trim_long.py's backup of an earlier train.jsonl would replace these rows.
(out / "train_full.jsonl").unlink(missing_ok=True)
for name, part in (("train", train), ("valid", valid), ("test", test)):
    write_jsonl(out / f"{name}.jsonl", [{"messages": student_messages(r, r["target"])} for r in part])
meta_keys = ["id", "source", "license", "category", "raw", "vocabulary", "place", "field", "spelling", "rules",
             "profile", "target"]
write_jsonl(out / "test_meta.jsonl", [{k: r.get(k) for k in meta_keys} for r in test])
write_jsonl(out / "all_filtered.jsonl", [{**{k: r.get(k) for k in meta_keys}, "split": s}
                                         for s, part in (("train", train), ("valid", valid), ("test", test))
                                         for r in part])
stats = dict(labelled=len(rows), kept=len(kept), train=len(train), valid=len(valid), test=len(test),
             drops=dict(drops), by_source=Counter(r["source"] for r in kept),
             nearest_to_bench=[dict(sim=round(s, 3), raw=t[:160], case=c) for s, t, c in near])
(out / "stats.json").write_text(json.dumps(stats, indent=2, ensure_ascii=False))
print(json.dumps({k: v for k, v in stats.items() if k != "nearest_to_bench"}, indent=1))
for n in stats["nearest_to_bench"][:8]:
    print(n)
