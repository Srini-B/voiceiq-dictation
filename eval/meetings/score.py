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
import html
import importlib.util
import json
import re
import unicodedata
from pathlib import Path

STEP = 0.01
COLLAR = 0.25


# One word normalizer for every scorer: "8%" and "eight percent", "31" and
# "thirty one" count as the same words, and HTML entities in reference text
# (AMI's we&#39;ve) are unescaped.
_spec = importlib.util.spec_from_file_location(
    "dictation_score", Path(__file__).resolve().parent.parent / "dictation" / "score.py")
_dictation = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_dictation)


def words(text: str) -> list[str]:
    return _dictation.words(html.unescape(text))


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
    # Frames within the collar of a speaker's turn boundary are not scored.
    # Each speaker's touching or overlapping segments merge into one turn
    # first, so splitting a turn into pieces cannot hide missed speech.
    turns = {}
    for s in sorted(ref, key=lambda s: s["start"]):
        spans = turns.setdefault(s["speaker"], [])
        if spans and s["start"] <= spans[-1][1]:
            spans[-1][1] = max(spans[-1][1], s["end"])
        else:
            spans.append([s["start"], s["end"]])
    skip = set()
    for spans in turns.values():
        for start, end in spans:
            for edge in (start, end):
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
    return errors, total


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
    return right, len(rw)


def edit_distance(r, h):
    d = list(range(len(h) + 1))
    for i in range(1, len(r) + 1):
        prev, d[0] = d[0], i
        for j in range(1, len(h) + 1):
            prev, d[j] = d[j], min(d[j] + 1, d[j - 1] + 1, prev + (r[i - 1] != h[j - 1]))
    return d[len(h)]


def cp_word_error(ref, hyp, m):
    # cpWER, the CHiME meeting metric: each person's words in time order
    # against the words given to that person, so order counts within a
    # speaker while overlap between speakers does not; words given to no
    # reference person are insertions.
    def stream(segments, key, who):
        return [w for s in sorted(segments, key=lambda s: s["start"]) if who(s[key]) for w in words(s["text"])]
    people = sorted({s["speaker"] for s in ref})
    errors = sum(edit_distance(stream(ref, "speaker", lambda x: x == p),
                               stream(hyp, "speaker_name", lambda x: m.get(x) == p)) for p in people)
    errors += len(stream(hyp, "speaker_name", lambda x: m.get(x) not in people))
    return errors, sum(len(words(s["text"])) for s in ref)


def counts(out, ref):
    """Error and total counts for one meeting, so several meetings pool."""
    ref_names = ref.get("participants")
    hyp, refseg = out["segments"], ref["segments"]
    m = mapping(refseg, hyp, ref_names)
    people = len(ref_names) if ref_names else len({s["speaker"] for s in refseg})
    return {"found": len({v for v in m.values() if v}), "people": people,
            "extra": len([h for h, v in m.items() if not v]),
            "der": der(refseg, hyp, m), "attr": attribution(refseg, hyp, m),
            "cpwer": cp_word_error(refseg, hyp, m), "mapping": m}


def scores(c):
    ratio = lambda pair: pair[0] / max(1, pair[1])
    return {"M1": round(max(0, 100 * c["found"] / max(1, c["people"]) - 10 * c["extra"]), 1),
            "M2": round(max(0, 100 * (1 - ratio(c["der"]))), 1),
            "M3": round(100 * ratio(c["attr"]), 1),
            "M4": round(max(0, 100 * (1 - ratio(c["cpwer"]))), 1)}


def main():
    ap = argparse.ArgumentParser(description="Scores OUTPUT REFERENCE pairs; with several pairs, "
                                 "the summary pools totals (error time over speech time, word errors "
                                 "over reference words), so long meetings weigh by their length.")
    ap.add_argument("files", nargs="+", help="OUTPUT REFERENCE [OUTPUT REFERENCE ...]")
    ap.add_argument("--packet", action="store_true")
    a = ap.parse_args()
    if len(a.files) % 2:
        ap.error("files come in OUTPUT REFERENCE pairs")
    pairs = [(json.loads(Path(o).read_text()), json.loads(Path(r).read_text()), o)
             for o, r in zip(a.files[::2], a.files[1::2])]
    if a.packet:
        for out, ref, _ in pairs:
            print(json.dumps({"reference_summary": ref.get("summary"), "notes": out.get("notes")}, ensure_ascii=False))
        return
    per = [(name, counts(out, ref)) for out, ref, name in pairs]
    if len(per) == 1:
        c = per[0][1]
        print(json.dumps({**scores(c), "speakers_ref": c["people"], "speakers_out": len(c["mapping"]),
                          "mapping": c["mapping"]}, indent=1, ensure_ascii=False))
        return
    pooled = {k: sum(c[k] for _, c in per) for k in ("found", "people", "extra")}
    for k in ("der", "attr", "cpwer"):
        pooled[k] = (sum(c[k][0] for _, c in per), sum(c[k][1] for _, c in per))
    print(json.dumps({"pooled": scores(pooled), "meetings": {n: scores(c) for n, c in per}},
                     indent=1, ensure_ascii=False))

if __name__ == "__main__":
    main()
