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


def d5(times: list[float]) -> dict:
    p50, p90 = statistics.median(times), percentile(times, 0.9)
    score = max(0.0, 100 - 15 * max(0, p50 - 3.0) - 10 * max(0, p90 - 3.5))
    return {"calls": len(times), "e2e_p50": round(p50, 2), "e2e_p90": round(p90, 2), "D5": round(score, 1)}


paths = sys.argv[1:]
if len(set(paths)) != len(paths):
    raise SystemExit("a run is listed twice")
pool, second, billed, per_run, settings = [], 0, 0, {}, set()
for path in paths:
    run = json.load(open(path))
    # As score.py: a partial run would drop its slowest or failed calls from the pool.
    if not run.get("complete") or run.get("failed"):
        raise SystemExit(f"{path}: incomplete run; rerun run.py with its label")
    if not run.get("screenshots"):
        raise SystemExit(f"{path}: screen context was off; D5 is measured with every option on")
    # Each call's fingerprint covers model, transport, screen setting, hedge ceiling,
    # prompt and audio, so equal sets mean the same experiment.
    settings.add(frozenset((r["id"], r["request"]) for r in run["results"]))
    times = [r["seconds"] + APP_OVERHEAD_S for r in run["results"]]
    pool += times
    second += sum(r["usage"].get("secondRequests", 0) > 0 for r in run["results"])
    billed += sum(r["usage"].get("billedSecondRequests", 0) > 0 for r in run["results"])
    per_run[path] = d5(times)["D5"]
if len(settings) > 1:
    raise SystemExit("runs differ in model, prompt, audio or hedge ceiling: pool only runs of one experiment")
report = {"runs": len(paths), **d5(pool), "e2e_max": round(max(pool), 2),
          "second_requests": f"{second}/{len(pool)}", "billed_second_requests": f"{billed}/{len(pool)}", "per_run_D5": per_run}
if len(paths) < 5:
    report["note"] = "fewer than 5 runs: not a D5 of record"
print(json.dumps(report, indent=1))
