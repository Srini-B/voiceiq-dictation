#!/usr/bin/env python3
"""Word error rate per stratum against the human references, no API calls.

Each draft is scored against the clip's INTENDED text (the clean written
reference) after lowercasing, stripping punctuation and writing spelled
numbers as digits on both sides, so cleanup the app is asked for (fillers
gone, digits) is not counted as error. Tamil is scored by character error
rate, because the references spell English loanwords in Tamil script.

Usage:
  wer.py results/LABEL.json                 a run.py result
  wer.py --ondevice ondevice_pro.json       raw on-device transcripts (writing Off)
"""
import argparse
import json
import re
import sys
import unicodedata
from collections import defaultdict
from pathlib import Path

import jiwer

HERE = Path(__file__).parent
sys.path.insert(0, str(HERE.parent / "dictation"))
from judge import DATA, INTENDED  # noqa: E402
from score import spelled_numbers_as_digits  # noqa: E402


def norm(text: str) -> str:
    text = unicodedata.normalize("NFKC", text).lower().replace("’", "'")
    text = re.sub(r"(?<=\d),(?=\d{3})", "", text)
    text = re.sub(r"[^\w\s'%$₹]", " ", text)
    text = re.sub(r"\s'|'\s", " ", text)
    return " ".join(spelled_numbers_as_digits(text.split()))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("result", nargs="?")
    ap.add_argument("--ondevice")
    args = ap.parse_args()
    clips = {c["id"]: c for c in map(json.loads, (DATA / "manifest.jsonl").read_text().splitlines())}
    extra = json.loads(INTENDED.read_text())
    if args.ondevice:
        drafts = json.loads(Path(args.ondevice).read_text())["texts"]
    else:
        drafts = {r["id"]: r["output"] for r in json.loads(Path(args.result).read_text())["results"]}
    by = defaultdict(lambda: [[], []])
    for cid, draft in drafts.items():
        clip = clips[cid]
        ref = norm(clip.get("intended") or extra[cid])
        by[clip["stratum"]][0].append(ref)
        by[clip["stratum"]][1].append(norm(draft) or "<empty>")
    total_e = total_n = 0
    for stratum, (refs, hyps) in sorted(by.items()):
        if stratum == "indicvoices_ta":
            rate = jiwer.cer(refs, hyps)
            print(f"{stratum:<16} n={len(refs):<4} CER={100 * rate:5.1f}%")
            continue
        o = jiwer.process_words(refs, hyps)
        n = o.hits + o.substitutions + o.deletions
        total_e += o.substitutions + o.deletions + o.insertions
        total_n += n
        print(f"{stratum:<16} n={len(refs):<4} WER={100 * o.wer:5.1f}%")
    print(f"{'English pooled':<16} WER={100 * total_e / max(total_n, 1):5.1f}%")


if __name__ == "__main__":
    main()
