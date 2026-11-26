#!/usr/bin/env python3
"""Scores one meeting the pipeline wrote against its reference (eval/SCORECARD.md).

Both files are JSON:
  output:    {"participants": ["Asha", ...], "segments": [{"start": s, "end": s,
              "speaker_name": "Asha", "text": "..."}], "notes": "markdown"}
  reference: {"participants": ["Asha", ...] or null when names are unknown (AMI),
              "segments": [{"start", "end", "speaker", "text"}],
              "summary": "reference notes or abstract"}

M1 participants found and named, M2 who spoke when (1 - DER, 0.25 s collar),
M3 who said what (reference words given to the right person) and M4 transcript
accuracy (1 - WER) are computed here. With reference names, output names are
matched by name; without them, by the best one-to-one overlap. `--packet`
prints the notes and summary for the judge (M5).
"""
import argparse
import json
import re
import unicodedata
from pathlib import Path

STEP = 0.01
COLLAR = 0.25


def words(text: str) -> list[str]:
    return re.findall(r"[\w']+", unicodedata.normalize("NFC", text.lower()))


def norm_name(name: str) -> str:
    # Accents fold away; letters in any script are kept.
    decomposed = unicodedata.normalize("NFKD", name.casefold())
    return " ".join("".join(c for c in decomposed if not unicodedata.combining(c)).split())


def match_names(hyp_names, ref_names):
    # Full names first, then a first name that points at exactly one
    # remaining person on both sides; never two speakers on one person.
    out, free = {}, list(ref_names)
    for h in hyp_names:
        r = next((r for r in free if norm_name(h) and norm_name(r) == norm_name(h)), None)
        if r:
            out[h] = r
            free.remove(r)
    first = lambda n: norm_name(n).split(" ")[0] if norm_name(n) else ""
    for h in [h for h in hyp_names if h not in out]:
        cands = [r for r in free if first(r) and first(r) == first(h)]
        rivals = [x for x in hyp_names if x not in out and first(x) == first(h)]
        if len(cands) == 1 and len(rivals) == 1:
            out[h] = cands[0]
            free.remove(cands[0])
    return {h: out.get(h) for h in hyp_names}


def frames(segments, key):
    out = {}
    for s in segments:
        for f in range(int(s["start"] / STEP), int(s["end"] / STEP)):
            out.setdefault(f, set()).add(s[key])
    return out


def mapping(ref, hyp, ref_names):
    hyp_names = sorted({s["speaker_name"] for s in hyp})
    if ref_names:
        return match_names(hyp_names, ref_names)
    ref_spk = sorted({s["speaker"] for s in ref})
    rf, hf = frames(ref, "speaker"), frames(hyp, "speaker_name")
    overlap = {(h, r): sum(1 for f, hs in hf.items() if h in hs and r in rf.get(f, ())) for h in hyp_names for r in ref_spk}
    # Best one-to-one assignment by overlap, as a DP over which reference
    # speakers are taken: polynomial in the larger side, exponential only in
    # the smaller one (12 x 12 is ~600k steps, not 12! permutations).
    from functools import lru_cache
    small_is_ref = len(ref_spk) <= len(hyp_names)
    small, large = (ref_spk, hyp_names) if small_is_ref else (hyp_names, ref_spk)
    weight = (lambda l, sm: overlap[(l, sm)]) if small_is_ref else (lambda l, sm: overlap[(sm, l)])

    @lru_cache(maxsize=None)
    def solve(i, taken):
        if i == len(large):
            return 0, ()
        best_v, best_p = solve(i + 1, taken)
        for j in range(len(small)):
            if not taken & (1 << j):
                v, p = solve(i + 1, taken | (1 << j))
                v += weight(large[i], small[j])
                if v > best_v:
                    best_v, best_p = v, ((large[i], small[j]),) + p
        return best_v, best_p

    pairs = solve(0, 0)[1]
    best = {sm: l for l, sm in pairs} if not small_is_ref else {l: sm for l, sm in pairs}
    return {h: best.get(h) for h in hyp_names}


def der(ref, hyp, m):
    # Frames within the collar of a reference boundary are not scored.
    skip = set()
    for s in ref:
        for edge in (s["start"], s["end"]):
            skip.update(range(int((edge - COLLAR) / STEP), int((edge + COLLAR) / STEP)))
    rf, hf = frames(ref, "speaker"), frames(hyp, "speaker_name")
    total = errors = 0
    for f in set(rf) | set(hf):
        if f in skip:
            continue
        r = rf.get(f, set())
        h = {m.get(x) or f"?{x}" for x in hf.get(f, set())}
        total += len(r)
        errors += max(len(r), len(h)) - len(r & h)
    return errors / max(1, total)


def timed_words(segments, key):
    out = []
    for s in segments:
        w = words(s["text"])
        for i, word in enumerate(w):
            out.append((s["start"] + (s["end"] - s["start"]) * (i + 0.5) / max(1, len(w)), word, s[key],
                        s["start"], s["end"]))
    return out


def attribution(ref, hyp, m):
    # Each output word can stand for one reference word only.
    hw = timed_words(hyp, "speaker_name")
    used = set()
    right = 0
    rw = timed_words(ref, "speaker")
    # A word's time inside a segment is only interpolated, so the gate is
    # segment overlap (with 1.5 s slack), not distance between guesses;
    # the nearest guess only picks among the candidates.
    for t, word, spk, start, end in rw:
        near = [i for i, h in enumerate(hw)
                if i not in used and h[1] == word and h[3] - 1.5 <= end and start <= h[4] + 1.5]
        if not near:
            continue
        # Equal distances prefer the occurrence given to the same person, so
        # overlapping speech scores the same whatever the segment order.
        i = min(near, key=lambda i: (abs(hw[i][0] - t), m.get(hw[i][2]) != spk))
        used.add(i)
        if m.get(hw[i][2]) == spk:
            right += 1
    return right / max(1, len(rw))


def bucket_word_error(ref, hyp, seconds=20):
    # Words compared as counts per 20-second stretch, so overlapping speech
    # scores the same however either side cuts it into segments; a wrong
    # word costs one error, as a substitution does in WER.
    from collections import Counter
    buckets = {}
    for side, segments, key in ((0, ref, "speaker"), (1, hyp, "speaker_name")):
        for t, word, *_ in timed_words(segments, key):
            buckets.setdefault(int(t // seconds), (Counter(), Counter()))[side][word] += 1
    errors = sum(max(sum((r - h).values()), sum((h - r).values())) for r, h in buckets.values())
    return errors / max(1, sum(sum(r.values()) for r, _ in buckets.values()))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("output")
    ap.add_argument("reference")
    ap.add_argument("--packet", action="store_true")
    a = ap.parse_args()
    out, ref = json.loads(Path(a.output).read_text()), json.loads(Path(a.reference).read_text())
    if a.packet:
        print(json.dumps({"reference_summary": ref.get("summary"), "notes": out.get("notes")}, ensure_ascii=False))
        return
    ref_names = ref.get("participants")
    hyp, refseg = out["segments"], ref["segments"]
    m = mapping(refseg, hyp, ref_names)
    ref_spk = sorted({s["speaker"] for s in refseg})
    found = len({v for v in m.values() if v})
    extra = len([h for h, v in m.items() if not v])
    if ref_names:
        named = len({v for v in m.values() if v})
        m1 = 100 * named / len(ref_names) - 10 * extra
    else:
        m1 = 100 * found / len(ref_spk) - 10 * extra
    m2 = 100 * (1 - der(refseg, hyp, m))
    m3 = 100 * attribution(refseg, hyp, m)
    m4 = 100 * (1 - bucket_word_error(refseg, hyp))
    print(json.dumps({"M1": round(max(0, m1), 1), "M2": round(max(0, m2), 1), "M3": round(m3, 1),
                      "M4": round(max(0, m4), 1), "speakers_ref": len(ref_spk), "speakers_out": len(m),
                      "mapping": m}, indent=1, ensure_ascii=False))


if __name__ == "__main__":
    main()
