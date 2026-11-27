#!/usr/bin/env python3
"""Plain word error rate of meeting transcripts, with speakers ignored inside a track.

score.py's M4 (cpWER) charges a word given to the wrong person twice, so it
cannot tell a transcription error from a speaker error. This reads the same
OUTPUT REFERENCE pairs and compares words only, one track at a time: the note
owner's reference words against the words written for the owner (`speaker_id`
"you"), and everyone else's reference words, in the order their turns start,
against the words written for anyone else. People talking over each other on
the far side cannot be put in one true order, so the far-side figure has a
floor above zero. The floor depends on how long the written turns are: an
output of 6 to 10 s lines orders overlapping speech differently from one of
word-timed turns, so far-side figures of such pipelines compare only roughly.

Each figure is printed twice: as spoken, and with hesitation sounds (um, uh,
mm-hmm) removed from both sides, since some models leave them out by design.

Usage: python3 wer.py OUTPUT REFERENCE [OUTPUT REFERENCE ...]
"""
import argparse
import importlib.util
import json
from pathlib import Path

_spec = importlib.util.spec_from_file_location("meetings_score", Path(__file__).resolve().parent / "score.py")
_score = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_score)

FILLERS = {"um", "uh", "uhm", "umm", "mm", "hmm", "hm", "mhm", "huh", "er", "erm", "ah", "eh"}


def edit_distance(ref, hyp):
    """Word edit distance by Myers' bit-vector method (Hyyrö's edit-distance form):
    one big-integer step per reference word, so two 6,000-word tracks take a moment.

    >>> edit_distance("a b c d".split(), "a x c".split())
    2
    >>> edit_distance([], "a b".split()), edit_distance("a b".split(), [])
    (2, 2)
    """
    if not hyp:
        return len(ref)
    where = {}
    for i, word in enumerate(hyp):
        where[word] = where.get(word, 0) | (1 << i)
    mask, top = (1 << len(hyp)) - 1, 1 << (len(hyp) - 1)
    plus, minus, distance = mask, 0, len(hyp)
    for word in ref:
        equal = where.get(word, 0)
        across = equal | minus
        down = (((equal & plus) + plus) ^ plus) | equal
        rise = minus | (~(down | plus) & mask)
        fall = plus & down
        distance += 1 if rise & top else -1 if fall & top else 0
        rise = ((rise << 1) | 1) & mask
        fall = (fall << 1) & mask
        plus = fall | (~(across | rise) & mask)
        minus = rise & across
    return distance


def streams(segments, owner_test):
    ordered = sorted(segments, key=lambda s: s["start"])
    mic = [w for s in ordered if owner_test(s) for w in _score.words(s["text"])]
    far = [w for s in ordered if not owner_test(s) for w in _score.words(s["text"])]
    return mic, far


def counts(out, ref):
    ref_mic, ref_far = streams(ref["segments"], lambda s: s["speaker"] == ref["owner"])
    hyp_mic, hyp_far = streams(out["segments"], lambda s: s["speaker_id"] == "you")
    plain = lambda words: [w for w in words if w not in FILLERS]
    result = {}
    for name, r, h in (("mic", ref_mic, hyp_mic), ("far", ref_far, hyp_far)):
        result[name] = (edit_distance(r, h), len(r))
        result[name + "_no_fillers"] = (edit_distance(plain(r), plain(h)), len(plain(r)))
    for suffix in ("", "_no_fillers"):
        result["all" + suffix] = tuple(result["mic" + suffix][i] + result["far" + suffix][i] for i in (0, 1))
    return result


def rates(c):
    return {k: round(100 * errors / max(1, total), 1) for k, (errors, total) in c.items()}


def main():
    ap = argparse.ArgumentParser(description="Plain WER per track for OUTPUT REFERENCE pairs; several pairs pool word errors over reference words.")
    ap.add_argument("files", nargs="+")
    a = ap.parse_args()
    if len(a.files) % 2:
        ap.error("files come in OUTPUT REFERENCE pairs")
    per = {o: counts(json.loads(Path(o).read_text()), json.loads(Path(r).read_text()))
           for o, r in zip(a.files[::2], a.files[1::2])}
    pooled = {k: tuple(sum(c[k][i] for c in per.values()) for i in (0, 1)) for k in next(iter(per.values()))}
    print(json.dumps({"pooled": rates(pooled), "count": len(per), "meetings": {n: rates(c) for n, c in per.items()}}, indent=1))


if __name__ == "__main__":
    main()
