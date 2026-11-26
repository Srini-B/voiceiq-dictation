#!/usr/bin/env python3
"""Word error rate of each variant's written text against what the TTS voice said.

Both sides are lowercased with punctuation removed and numbers left as the
writer wrote them, so a difference in formatting ("three" vs "3") counts as an
error for both variants alike. Clips with spoken commands, fillers or edits are
left out because their right text differs from the script.

python3 wer.py rows.json
"""
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

SKIP = {"eval_self_correction", "eval_punctuation", "eval_all_filler", "eval_spoken_list", "long_01", "long_02"}
manifest = json.loads(Path(".amp/in/orb-backup/eval/manifest.json").read_text())
script = {c["id"]: c["text"] for c in manifest["clips"]}


def words(text):
    text = text.lower().replace("o'clock", "").replace("’", "'")
    return re.findall(r"[a-z0-9']+", text)


def distance(a, b):
    d = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        prev, d[0] = d[0], i
        for j, y in enumerate(b, 1):
            prev, d[j] = d[j], min(d[j] + 1, d[j - 1] + 1, prev + (x != y))
    return d[len(b)]


errors, total, worst = defaultdict(int), defaultdict(int), defaultdict(list)
for r in json.load(open(sys.argv[1])):
    base = r["id"].removesuffix("_noisy")
    if base in SKIP or base not in script or not r["ok"]:
        continue
    ref, hyp = words(script[base]), words(r["text"])
    e = distance(ref, hyp)
    errors[r["variant"]] += e
    total[r["variant"]] += len(ref)
    if e:
        worst[r["variant"]].append((e, r["id"], r["text"][:120]))
for v in sorted(total):
    print(f"{v}: WER {100 * errors[v] / total[v]:.1f}% ({errors[v]} errors / {total[v]} words)")
    for e, i, t in sorted(worst[v], reverse=True)[:8]:
        print(f"   {e} {i}: {t}")
