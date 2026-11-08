"""Labels raw dictations with the production cleanup: Claude Sonnet 5.5 and the
exact PromptV1 prompt (common.teacher_request), through the Message Batches
API. Appends to the output file and skips ids it already holds, so a rerun
resumes. Prints the measured cost per example and the projection for the rest.

usage: python label.py data/inputs_public.jsonl data/inputs_synthetic.jsonl --out data/labelled.jsonl \
           [--sample 300 --seed 3] [--dry-run]
"""
import argparse
import hashlib
import json
import random
import time
from collections import Counter
from pathlib import Path

import anthropic

from common import BATCH_DISCOUNT, PRICE, read_jsonl, teacher_request

p = argparse.ArgumentParser()
p.add_argument("inputs", nargs="+")
p.add_argument("--out", required=True)
p.add_argument("--sample", type=int, default=0, help="label a stratified sample of this many new inputs")
p.add_argument("--seed", type=int, default=3)
p.add_argument("--dry-run", action="store_true", help="print the projection without submitting")
args = p.parse_args()


def rid(r):
    return r.get("id") or hashlib.sha1((r["source"] + "\x00" + r["raw"]).encode()).hexdigest()[:16]


pool = []
for path in args.inputs:
    for r in read_jsonl(path):
        r["id"] = rid(r)
        pool.append(r)
out = Path(args.out)
# Failed, expired or cancelled requests stay eligible for the next run.
done = {r["id"] for r in read_jsonl(out) if r.get("target") is not None} if out.exists() else set()
todo = [r for r in {r["id"]: r for r in pool}.values() if r["id"] not in done]
if args.sample:
    rng = random.Random(args.seed)
    rng.shuffle(todo)
    todo.sort(key=lambda r: r["category"])  # stratify: every nth row of the category-sorted list
    step = max(1, len(todo) // args.sample)
    todo = todo[::step][: args.sample]
print(f"{len(todo)} to label ({len(done)} already labelled)")


def cost(u):
    cw = u.get("cache_creation") or {}
    w1h = cw.get("ephemeral_1h_input_tokens", 0)
    w5m = cw.get("ephemeral_5m_input_tokens", u.get("cache_creation_input_tokens", 0) - w1h)
    usd = (u["input_tokens"] * PRICE["input"] + u.get("cache_read_input_tokens", 0) * PRICE["cache_read"]
           + w1h * PRICE["cache_write_1h"] + w5m * PRICE["input"] * 1.25 + u["output_tokens"] * PRICE["output"]) / 1e6
    return usd * BATCH_DISCOUNT


def report(rows, remaining):
    rows = [r for r in rows if r.get("usage")]
    if not rows:
        return
    tot = sum(r["cost_usd"] for r in rows)
    keys = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens", "output_tokens"]
    mean = {k: round(sum(r["usage"].get(k, 0) for r in rows) / len(rows)) for k in keys}
    print(f"labelled {len(rows)}: ${tot:.2f} total, ${tot / len(rows):.5f} per example (batch price), mean usage {mean}")
    print(f"stop reasons {Counter(r['stop_reason'] for r in rows)}")
    if remaining:
        print(f"projected for {remaining} more: ${tot / len(rows) * remaining:.2f}")


if args.dry_run or not todo:
    report(read_jsonl(out) if out.exists() else [], len(todo))
    raise SystemExit

client = anthropic.Anthropic(max_retries=8)
# Batches share the prompt cache only on a best-effort basis; one synchronous
# call first writes the shared rules into the one-hour cache.
warm = teacher_request({"raw": "okay"})
warm["max_tokens"] = 16
client.messages.create(**warm)

out.parent.mkdir(parents=True, exist_ok=True)
state = out.with_suffix(".batches.json")
batches = json.loads(state.read_text()) if state.exists() else []
by_id = {r["id"]: r for r in pool}
# A rerun with a state file only collects the batches it already submitted.
# Each request repeats the ~45k-character rules, so batches stay well under
# the API's 256 MB request limit and the orb's memory.
CHUNK = 2500
for i in range(0, len(todo) if not batches else 0, CHUNK):
    chunk = todo[i:i + CHUNK]
    b = client.messages.batches.create(requests=[{"custom_id": r["id"], "params": teacher_request(r)} for r in chunk])
    batches.append(b.id)
    state.write_text(json.dumps(batches))
    print(f"submitted {b.id} ({len(chunk)} requests)")

t0 = time.time()
for bid in batches:
    while (b := client.messages.batches.retrieve(bid)).processing_status != "ended":
        print(f"{bid}: {b.request_counts} ({time.time() - t0:.0f}s)", flush=True)
        time.sleep(60)
    written = []
    with open(out, "a") as f:
        for res in client.messages.batches.results(bid):
            src = by_id.get(res.custom_id)
            if src is None or res.custom_id in done:
                continue
            row = dict(src)
            if res.result.type == "succeeded":
                m = res.result.message
                u = m.usage.model_dump()
                row.update(target="".join(c.text for c in m.content if c.type == "text"), stop_reason=m.stop_reason,
                           teacher=m.model, usage=u, cost_usd=cost(u))
            else:
                row.update(target=None, stop_reason=res.result.type, error=str(getattr(res.result, "error", "")))
            if row["target"] is not None:
                done.add(res.custom_id)
            written.append(row)
            f.write(json.dumps(row, ensure_ascii=False) + "\n")
    print(f"{bid}: wrote {len(written)} rows in {time.time() - t0:.0f}s")
state.unlink()
remaining = len({r["id"] for r in pool} - done)
report(read_jsonl(out), remaining)
