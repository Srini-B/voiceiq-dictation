"""Scores benchmark outputs: per-case checks, the production ValidationGate,
and similarity to the reference. `python score.py --self-test` scores the
references themselves (every check must pass).

usage: python score.py [--cases rules_cases.jsonl] results/*.jsonl > report.md
"""
import difflib
import json
import re
import sys
from collections import defaultdict

CASES = sys.argv[sys.argv.index("--cases") + 1] if "--cases" in sys.argv else "cases.jsonl"
cases = {c["id"]: c for c in map(json.loads, open(CASES))}

# --- Port of ValidationGate.swift ------------------------------------------
NUM = [("zero", "0"), ("one", "1"), ("two", "2"), ("three", "3"), ("four", "4"), ("five", "5"), ("six", "6"),
       ("seven", "7"), ("eight", "8"), ("nine", "9"), ("ten", "10"), ("eleven", "11"), ("twelve", "12"),
       ("twenty", "20"), ("thirty", "30"), ("forty", "40"), ("fifty", "50"), ("hundred", "100")]
ANSWER = re.compile(r"^(sure|okay|certainly|of course|great question|here('s| is)|i can('|no)t|as an ai|i'm (sorry|an ai))\b", re.I)


def normalize(t):
    s = t.lower()
    for w, d in NUM:
        s = re.sub(rf"\b{w}\b", d, s)
    return s


def words(t):
    return [w for w in re.split(r"[^0-9a-zà-ÿ]+", normalize(t)) if w]


def trigrams(s):
    ch = [c for c in s if not c.isspace()]
    if len(ch) < 3:
        return {"".join(ch)} if ch else set()
    return {"".join(ch[i:i + 3]) for i in range(len(ch) - 2)}


def gate(raw, cleaned):
    rw, cw = words(raw), words(cleaned)
    if not cw:
        return "ok" if not rw else "empty_output"
    if ANSWER.search(cleaned) and cw[0] != (rw[0] if rw else None):
        return "answer_pattern"
    if "as an ai" in cleaned.lower() or "language model" in cleaned.lower():
        return "ai_selfreference"
    rend = raw.strip().rstrip(".,!?;: ").lower()
    if (raw.strip().endswith("?") or rend.endswith("question mark")) and not cleaned.strip().endswith("?") \
            and any(w not in set(rw) for w in cw):
        return "question_answered"
    ratio = len(cw) / len(rw)
    if len(rw) >= 3 and ratio > 1.6:
        return f"expansion_{ratio:.2f}"
    if len(rw) >= 6 and ratio < 0.2:
        return f"shrink_{ratio:.2f}"
    contained = sum(1 for w in cw if w in set(rw)) / len(cw)
    ta, tb = trigrams(normalize(raw)), trigrams(normalize(cleaned))
    tri = len(ta & tb) / min(len(ta), len(tb)) if ta and tb else 0
    if contained < 0.5 and tri < 0.55:
        return "divergence"
    return "ok"


def strip_artifacts(t):
    s = t.strip()
    if s.startswith("```"):
        s = re.sub(r"```[a-z]*\n?", "", s).replace("```", "").strip()
    for label in ["CLEAN:", "Clean:", "Transcript:", "TRANSCRIPT:"]:
        if s.startswith(label):
            s = s[len(label):].strip()
    if len(s) > 1 and s.startswith('"') and s.endswith('"'):
        s = s[1:-1]
    return s


def check(c, out):
    fails = []
    for s in c["must"]:
        if s not in out:
            fails.append(f"missing {s!r}")
    for s in c["must_not"]:
        if s.lower() in out.lower():
            fails.append(f"has {s!r}")
    for r in c["regex"]:
        if not re.search(r, out, re.M):
            fails.append(f"no /{r}/")
    for r in c["not_regex"]:
        if re.search(r, out, re.M):
            fails.append(f"matches /{r}/")
    return fails


if "--self-test" in sys.argv:
    bad = 0
    for c in cases.values():
        f = check(c, c["reference"])
        g = gate(c["raw"], c["reference"])
        if f or g != "ok":
            bad += 1
            print(c["id"], f, g)
    print(f"{len(cases) - bad}/{len(cases)} references pass")
    sys.exit(1 if bad else 0)

rows, detail = [], []
for path in [a for a in sys.argv[1:] if a.endswith(".jsonl") and a != CASES]:
    lines = [json.loads(l) for l in open(path)]
    meta, recs = lines[0]["meta"], lines[1:]
    by_cat = defaultdict(lambda: [0, 0])
    passed = gated = 0
    sims, totals, tps, peaks, ttfts = [], [], [], [], []
    cold = next((r["cold"] for r in recs if r.get("cold")), None)
    for r in recs:
        c = cases[r["id"]]
        out = strip_artifacts(r["output"])
        f = check(c, out)
        g = gate(c["raw"], out)
        ok = not f and g == "ok"
        passed += ok
        gated += g != "ok"
        by_cat[c["category"]][0] += ok
        by_cat[c["category"]][1] += 1
        sims.append(difflib.SequenceMatcher(None, out, c["reference"]).ratio())
        totals.append(r["total_s"]); tps.append(r["gen_tps"]); peaks.append(r["peak_gb"]); ttfts.append(r["ttft_s"])
        detail.append((meta["model"], c["id"], ok, f, g, out))
    n = len(recs)
    rows.append(dict(model=meta["model"], pass_rate=passed / n, passed=passed, n=n, gate_rejects=gated,
                     similarity=sum(sims) / n, median_total_s=sorted(totals)[n // 2], gen_tps=sorted(tps)[n // 2],
                     ttft_s=sorted(ttfts)[n // 2], peak_gb=max(peaks), weights_gb=meta["weights_gb"],
                     prefix_tokens=meta["prefix_tokens"], prefix_prefill_s=meta["prefix_prefill_s"],
                     prefix_peak_gb=meta["prefix_peak_gb"], cache_mb=meta["cache_file_mb"], cold=cold,
                     by_cat={k: f"{v[0]}/{v[1]}" for k, v in sorted(by_cat.items())}))

rows.sort(key=lambda r: -r["pass_rate"])
print("| Model | Passed | Gate rejects | Similarity | Median total s | Gen tok/s | Cached TTFT s | Cold TTFT s | Peak GB (cold) | Weights GB | Prefix tokens | Prefix prefill s |")
print("|---|---|---|---|---|---|---|---|---|---|---|---|")
for r in rows:
    cold = r["cold"] or {}
    print(f"| {r['model']} | {r['passed']}/{r['n']} | {r['gate_rejects']} | {r['similarity']:.2f} | {r['median_total_s']:.2f} | {r['gen_tps']:.0f} | {r['ttft_s']:.2f} | {cold.get('ttft_s', '-')} | {cold.get('peak_gb', '-')} | {r['weights_gb']:.2f} | {r['prefix_tokens']} | {r['prefix_prefill_s']} |")
print()
cats = sorted({k for r in rows for k in r["by_cat"]})
print("| Model | " + " | ".join(cats) + " |")
print("|---|" + "---|" * len(cats))
for r in rows:
    print(f"| {r['model']} | " + " | ".join(r["by_cat"].get(k, "-") for k in cats) + " |")
if "--detail" in sys.argv:
    print()
    for model, cid, ok, f, g, out in detail:
        if not ok:
            print(f"### {model} / {cid}: {'; '.join(f)} gate={g}\n```\n{out}\n```\n")
