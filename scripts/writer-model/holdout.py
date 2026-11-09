"""Lists rows of already filtered data that overlap benchmark cases written
after it was filtered (a shared 13-word sequence, or embedding similarity of
RAW at or above --sim, as filter.py checks). make_mix.py --drop leaves them out.

usage: python holdout.py data/mlx/all_filtered.jsonl data/mlx_targeted/all_filtered.jsonl \
           --cases bench/rules_cases.jsonl --out data/holdout_rules_cases.jsonl
"""
import argparse
import re

from sentence_transformers import SentenceTransformer

from common import read_jsonl, write_jsonl

p = argparse.ArgumentParser()
p.add_argument("rows", nargs="+")
p.add_argument("--cases", required=True)
p.add_argument("--out", required=True)
p.add_argument("--sim", type=float, default=0.65)
p.add_argument("--embed-model", default="sentence-transformers/all-MiniLM-L6-v2")
args = p.parse_args()


def shingles(s, n=13):
    w = re.findall(r"[a-z0-9']+", s.lower())
    return {" ".join(w[i:i + n]) for i in range(len(w) - n + 1)}


cases = read_jsonl(args.cases)
rows = [r for path in args.rows for r in read_jsonl(path)]
if not rows:
    write_jsonl(args.out, [])
    raise SystemExit("0 rows to check")
bench = set().union(*(shingles(c["raw"]) | shingles(c["reference"]) for c in cases))
emb = SentenceTransformer(args.embed_model, device="cpu")
cv = emb.encode([c["raw"] for c in cases], normalize_embeddings=True)
rv = emb.encode([r["raw"] for r in rows], normalize_embeddings=True, batch_size=128, show_progress_bar=True)
sims = rv @ cv.T
hits = []
for i, r in enumerate(rows):
    j = int(sims[i].argmax())
    if sims[i, j] >= args.sim or (shingles(r["raw"]) | shingles(r["target"])) & bench:
        hits.append(dict(id=r["id"], split=r.get("split"), raw=r["raw"], target=r["target"], case=cases[j]["id"],
                         sim=round(float(sims[i, j]), 3)))
write_jsonl(args.out, hits)
print(f"{len(hits)} of {len(rows)} rows overlap {len(cases)} cases")
