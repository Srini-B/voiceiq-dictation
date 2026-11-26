#!/usr/bin/env python3
"""D5 pooled over several runs, the way the judge takes it: the same commit
run at least five times through the day, every call's key-up-to-text time
in one pool, p50 and p90 over the pool. Run main in the same sessions, one
run each, alternating, so both see the same API load.

Usage: pool_latency.py results/<label-1>.json results/<label-2>.json ...
"""
import json
import statistics
import sys

from score import APP_OVERHEAD_S, percentile

e2e, second, runs = [], 0, 0
for path in sys.argv[1:]:
    run = json.load(open(path))
    runs += 1
    for r in run["results"]:
        e2e.append(r["seconds"] + APP_OVERHEAD_S)
        second += r["usage"].get("secondRequests", 0) > 0
p50, p90 = statistics.median(e2e), percentile(e2e, 0.9)
d5 = max(0.0, 100 - 15 * max(0, p50 - 3.0) - 10 * max(0, p90 - 3.5))
print(json.dumps({"runs": runs, "calls": len(e2e), "e2e_p50": round(p50, 2), "e2e_p90": round(p90, 2),
                  "e2e_max": round(max(e2e), 2), "second_requests": f"{second}/{len(e2e)}", "D5": round(d5, 1)},
                 indent=1))
