#!/usr/bin/env python3
"""Per-category breakdown of a bench result file: python3 breakdown.py rows.json [--misses]"""
import json
import sys
from collections import defaultdict

rows = json.load(open(sys.argv[1]))
agg = defaultdict(lambda: defaultdict(int))
for r in rows:
    a = agg[(r["category"], r["variant"])]
    a["names_hit"] += r["names_hit"]; a["names_total"] += r["names_total"]
    a["english_kept"] += r["english_kept"]; a["english_total"] += r["english_total"]
    a["flips"] += len(r["flips"]); a["failed"] += not r["eval_ok"]; a["n"] += 1
for (cat, v), a in sorted(agg.items()):
    print(f"{cat:22s} {v} n={a['n']:3d} names {a['names_hit']:3d}/{a['names_total']:3d} "
          f"english kept {a['english_kept']:2d}/{a['english_total']:2d} flips {a['flips']:2d} failed {a['failed']}")
if "--misses" in sys.argv:
    for r in rows:
        if r.get("missed") or r["flips"] or not r["eval_ok"] or r["english_kept"] < r["english_total"]:
            print(f"{r['variant']} r{r['round']} {r['id']}: missed={r.get('missed')} flips={r['flips']} | {r['text'][:160]!r}")
