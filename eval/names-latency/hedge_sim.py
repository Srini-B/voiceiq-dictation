#!/usr/bin/env python3
"""What an earlier hedge would do to measured call times.

A dictation's answer is min(first, start + second): the second request starts
`start` seconds after the first and both run on their own. The second call's
time is drawn from the same variant's other measured calls (bootstrap), so the
effect is estimated from the real distribution, not assumed.

python3 hedge_sim.py rows.json [overhead_seconds]
"""
import json
import random
import statistics
import sys
from collections import defaultdict

rows = json.load(open(sys.argv[1]))
overhead = float(sys.argv[2]) if len(sys.argv) > 2 else 0.0
by_variant = defaultdict(list)
for r in rows:
    if r["ok"]:
        by_variant[r["variant"]].append(r["dt"])
random.seed(1)


def pct(values, p):
    values = sorted(values)
    return values[min(len(values) - 1, int(round(p * (len(values) - 1))))]


for variant, times in sorted(by_variant.items()):
    print(f"variant {variant}: {len(times)} calls")
    for start in [None, 20, 5, 3.0, 2.5, 2.0, 1.5, 1.0, 0.0]:
        totals, extra = [], 0
        for _ in range(20):
            for t in times:
                if start is None or t <= start:
                    totals.append(t + overhead)
                    continue
                extra += 1
                totals.append(min(t, start + random.choice(times)) + overhead)
        label = "no hedge" if start is None else f"hedge at {start:>4}s"
        print(f"  {label}: p50 {pct(totals, .5):.2f}s p90 {pct(totals, .9):.2f}s p99 {pct(totals, .99):.2f}s "
              f"max {max(totals):.2f}s, second request in {100 * extra / len(totals):.0f}% of dictations")
