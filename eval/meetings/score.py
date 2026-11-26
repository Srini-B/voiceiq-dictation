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
import itertools
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
        r = next((r for r in free if norm_name(r) == norm_name(h)), None)
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
    best, best_score = {}, -1
    small, large = (hyp_names, ref_spk) if len(hyp_names) <= len(ref_spk) else (ref_spk, hyp_names)
    for perm in itertools.permutations(large, len(small)):
        pairs = dict(zip(small, perm)) if small is hyp_names else {p: s for s, p in zip(small, perm)}
        score = sum(overlap[(h, r)] for h, r in pairs.items())
        if score > best_score:
            best, best_score = pairs, score
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
            out.append((s["start"] + (s["end"] - s["start"]) * (i + 0.5) / max(1, len(w)), word, s[key]))
    return out


def attribution(ref, hyp, m):
    # Each output word can stand for one reference word only.
    hw = timed_words(hyp, "speaker_name")
    used = set()
    right = 0
    rw = timed_words(ref, "speaker")
    for t, word, spk in rw:
        near = [i for i, h in enumerate(hw) if i not in used and abs(h[0] - t) <= 1.5 and h[1] == word]
        if not near:
            continue
        i = min(near, key=lambda i: abs(hw[i][0] - t))
        used.add(i)
        if m.get(hw[i][2]) == spk:
            right += 1
    return right / max(1, len(rw))


def wer(ref_text, hyp_text):
    r, h = words(ref_text), words(hyp_text)
    d = list(range(len(h) + 1))
    for i in range(1, len(r) + 1):
        prev, d[0] = d[0], i
        for j in range(1, len(h) + 1):
            prev, d[j] = d[j], min(d[j] + 1, d[j - 1] + 1, prev + (r[i - 1] != h[j - 1]))
    return d[len(h)] / max(1, len(r))


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
    m4 = 100 * (1 - wer(" ".join(s["text"] for s in sorted(refseg, key=lambda s: s["start"])),
                        " ".join(s["text"] for s in sorted(hyp, key=lambda s: s["start"]))))
    print(json.dumps({"M1": round(max(0, m1), 1), "M2": round(max(0, m2), 1), "M3": round(m3, 1),
                      "M4": round(max(0, m4), 1), "speakers_ref": len(ref_spk), "speakers_out": len(m),
                      "mapping": m}, indent=1, ensure_ascii=False))


if __name__ == "__main__":
    main()
