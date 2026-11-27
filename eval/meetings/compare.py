#!/usr/bin/env python3
"""Compares pipelines on the same meetings: M1–M4 (score.py), plain WER (wer.py) and run time.

Each pipeline is a folder of <meeting-id>.json outputs. Only meetings every
named pipeline has are compared. Prints Markdown: one pooled table, then one
table per meeting.

`--drop-unmatched` first removes every turn of a speaker score.py matches to
nobody. On AMI that speaker is usually the owner's own voice heard by the
other headsets, which a real call's far side would not carry, so the second
reading estimates what the room costs each pipeline. It is uneven: an output
without word times keeps leaked words inside other people's lines, and when
an echo drop removes most of the owner's mic lines the speaker removed is
what is left of the mic.

Usage: python3 compare.py [--drop-unmatched] DATA_DIR PIPELINE_DIR [PIPELINE_DIR ...]
"""
import importlib.util
import json
import sys
from pathlib import Path


def load(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).resolve().parent / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


score, wer = load("score"), load("wer")


def row(label, m1, counts, errors, seconds, duration, speakers):
    s, w = score.scores(counts), wer.rates(errors)
    speed = f"{seconds:.0f} s ({duration / seconds:.0f}× real time)" if seconds else "n/a"
    return (f"| {label} | {m1} | {s['M2']} | {s['M3']} | {s['M4']} | {w['all']} | {w['mic']} | {w['far']} | "
            f"{w['all_no_fillers']} | {speakers} | {speed} |")


HEADER = ("| Pipeline | M1 | M2 | M3 | M4 | WER | WER mic | WER far | WER, no fillers | Speakers written (matched to nobody) | Run time |\n"
          "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")


def main():
    args = [a for a in sys.argv[1:] if a != "--drop-unmatched"]
    drop_unmatched = len(args) < len(sys.argv) - 1
    data, pipelines = Path(args[0]), [Path(p) for p in args[1:]]
    if len({p.name for p in pipelines}) < len(pipelines):
        raise SystemExit("two pipeline folders share a name; rows are labelled by folder name")
    meetings = sorted(set.intersection(*({f.stem for f in p.glob("*.json")} for p in pipelines)))
    if not meetings:
        raise SystemExit("the pipeline folders have no meeting in common")
    results = {}
    for pipeline in pipelines:
        for meeting in meetings:
            out = json.loads((pipeline / f"{meeting}.json").read_text())
            ref = json.loads((data / meeting / "reference.json").read_text())
            if drop_unmatched:
                unmatched = {name for name, person in score.counts(out, ref)["mapping"].items() if not person}
                out["segments"] = [s for s in out["segments"] if s["speaker_name"] not in unmatched]
            results[pipeline.name, meeting] = (score.counts(out, ref), wer.counts(out, ref),
                                               out.get("seconds", {}).get("transcribe", 0), out.get("duration_seconds", 0))
    print(f"Pooled over {len(meetings)} meetings ({', '.join(meetings)})"
          + (", speakers matched to nobody removed" if drop_unmatched else "") + ".\n")
    print(HEADER)
    for pipeline in pipelines:
        per = [results[pipeline.name, m] for m in meetings]
        pooled = {k: sum(c[k] for c, _, _, _ in per) for k in ("found", "people", "extra")}
        for k in ("der", "attr", "cpwer"):
            pooled[k] = tuple(sum(c[k][i] for c, _, _, _ in per) for i in (0, 1))
        errors = {k: tuple(sum(e[k][i] for _, e, _, _ in per) for i in (0, 1)) for k in per[0][1]}
        # M1 is the mean of the meetings' own scores, as score.py pools it.
        m1 = round(sum(score.scores(c)["M1"] for c, _, _, _ in per) / len(per), 1)
        speakers = f"{sum(len(c['mapping']) for c, _, _, _ in per)} ({pooled['extra']})"
        print(row(pipeline.name, m1, pooled, errors, sum(p[2] for p in per), sum(p[3] for p in per), speakers))
    for meeting in meetings:
        print(f"\n{meeting}\n")
        print(HEADER)
        for pipeline in pipelines:
            counts, errors, seconds, duration = results[pipeline.name, meeting]
            print(row(pipeline.name, score.scores(counts)["M1"], counts, errors, seconds, duration,
                      f"{len(counts['mapping'])} ({counts['extra']})"))


if __name__ == "__main__":
    main()
