#!/usr/bin/env python3
"""Scores a run.py result against eval/SCORECARD.md.

D1 names and sound-alikes, D2 word accuracy and D5 latency are computed
here. D3 multilingual and D4 cleanup need a judge: `score.py RESULT --packet`
prints the cases for the judge (Claude Fable 5.2), and
`score.py RESULT --judge judge.json` folds its 0-100 scores in.
judge.json maps "<case id>/r<round>" to a score.
"""
import argparse
import json
import re
import statistics
import unicodedata
from pathlib import Path

HERE = Path(__file__).parent
# Measured app work outside the model call on a signed build (2026-11-18):
# finalize 0.23 s + FLAC encode 0.03 s + insert 0.13 s.
APP_OVERHEAD_S = 0.39


def words(text: str) -> list[str]:
    text = unicodedata.normalize("NFC", text.lower())
    return re.findall(r"[\w']+", text)


def wer(ref: str, hyp: str) -> float:
    r, h = words(ref), words(hyp)
    d = list(range(len(h) + 1))
    for i in range(1, len(r) + 1):
        prev, d[0] = d[0], i
        for j in range(1, len(h) + 1):
            prev, d[j] = d[j], min(d[j] + 1, d[j - 1] + 1, prev + (r[i - 1] != h[j - 1]))
    return d[len(h)] / max(1, len(r))


def has_word(term: str, text: str) -> bool:
    return re.search(rf"(?<!\w){re.escape(term)}(?!\w)", text) is not None


def percentile(values: list[float], q: float) -> float:
    s = sorted(values)
    return s[min(len(s) - 1, int(round(q * (len(s) - 1))))]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("result")
    ap.add_argument("--packet", action="store_true")
    ap.add_argument("--judge")
    args = ap.parse_args()
    spec = {c["id"]: c for c in json.loads((HERE / "cases.json").read_text())["cases"]}
    run = json.loads(Path(args.result).read_text())
    results = run["results"]

    if args.packet:
        for r in results:
            c = spec[r["id"]]
            if c["item"] in ("D3", "D4"):
                print(json.dumps({"key": f"{r['id']}/r{r['round']}", "item": c["item"], "spoken": c["text"],
                                  "field_before_cursor": c.get("before"), "expected": c["expect"],
                                  "output": r["output"]}, ensure_ascii=False))
        return

    # D1: every dictionary or on-screen name written exactly; each English
    # control word swapped for a listed name costs 10 points per round: a
    # silent wrong name in a sent message is worse than a missed one.
    hit = total = flips = 0
    misses = []
    for r in results:
        c = spec[r["id"]]
        for t in c.get("targets", []):
            total += 1
            if has_word(t, r["output"]):
                hit += 1
            else:
                misses.append(f"{r['id']}: {t}")
        for w in c.get("controls", []):
            if not has_word(w, r["output"]):
                flips += 1
                misses.append(f"{r['id']}: control {w} changed")
    d1 = max(0.0, 100 * hit / total - 10 * flips / max(1, len({r['round'] for r in results})))

    # D2: word accuracy on cases whose expected text is the spoken text.
    wers = [wer(spec[r["id"]]["text"], r["output"]) for r in results if spec[r["id"]]["item"] in ("D1", "D5")]
    d2 = max(0.0, 100 * (1 - statistics.mean(wers)))

    # D5: key-up to inserted text = model call + app overhead, all options on.
    e2e = [r["seconds"] + APP_OVERHEAD_S for r in results]
    p50, p90 = statistics.median(e2e), percentile(e2e, 0.9)
    d5 = max(0.0, 100 - 15 * max(0, p50 - 3.0) - 10 * max(0, p90 - 3.5))

    # Hard rules for D3/D4, applied before and over the judge.
    hard = {}
    for r in results:
        c = spec[r["id"]]
        key = f"{r['id']}/r{r['round']}"
        out = r["output"]
        if c.get("expect") == "<<EMPTY>>":
            hard[key] = 100 if out == "" else 0
        if any(w.lower() in out.lower() for w in c.get("must_not", [])):
            hard[key] = 0
        if c.get("must_end") and not out.rstrip().endswith(c["must_end"]):
            hard[key] = min(hard.get(key, 100), 50)

    judged = json.loads(Path(args.judge).read_text()) if args.judge else {}
    items = {"D1": d1, "D2": d2, "D5": d5}
    for item in ("D3", "D4"):
        scores = []
        for r in results:
            if spec[r["id"]]["item"] != item:
                continue
            key = f"{r['id']}/r{r['round']}"
            s = judged.get(key)
            if key in hard:
                s = hard[key] if s is None else min(s, hard[key])
            if s is not None:
                scores.append(s)
        items[item] = statistics.mean(scores) if scores else None

    thoughts = [r["usage"].get("thoughtsTokenCount", 0) for r in results]
    report = {"label": run["label"], "prompt_chars": run["prompt_chars"], "calls": len(results),
              "scores": {k: (round(v, 1) if v is not None else None) for k, v in items.items()},
              "names": f"{hit}/{total}", "control_flips": flips, "mean_wer": round(statistics.mean(wers), 3),
              "e2e_p50": round(p50, 2), "e2e_p90": round(p90, 2), "e2e_max": round(max(e2e), 2),
              "calls_with_thinking": sum(t > 0 for t in thoughts), "misses": misses}
    print(json.dumps(report, indent=1, ensure_ascii=False))


if __name__ == "__main__":
    main()
