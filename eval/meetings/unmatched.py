#!/usr/bin/env python3
"""Who the speakers matched to nobody are.

For every speaker score.py matches to no reference person, prints how long
they speak, how many words they have, and how much of their time falls inside
the note owner's reference turns. On AMI a high share means the speaker is
the owner's voice heard by the other headsets.

Usage: python3 unmatched.py DATA_DIR PIPELINE_DIR [meeting-id ...]
"""
import importlib.util
import json
import sys
from pathlib import Path

_spec = importlib.util.spec_from_file_location("meetings_score", Path(__file__).resolve().parent / "score.py")
score = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(score)


def shared(start, end, turns):
    return sum(max(0, min(end, b) - max(start, a)) for a, b in turns)


def main():
    data, pipeline, only = Path(sys.argv[1]), Path(sys.argv[2]), set(sys.argv[3:])
    for path in sorted(pipeline.glob("*.json")):
        if only and path.stem not in only:
            continue
        out = json.loads(path.read_text())
        ref = json.loads((data / path.stem / "reference.json").read_text())
        owner = [(t["start"], t["end"]) for t in ref["segments"] if t["speaker"] == ref["owner"]]
        for name, person in score.counts(out, ref)["mapping"].items():
            if person:
                continue
            turns = [s for s in out["segments"] if s["speaker_name"] == name]
            seconds = sum(s["end"] - s["start"] for s in turns)
            inside = sum(shared(s["start"], s["end"], owner) for s in turns)
            words = sum(len(s["text"].split()) for s in turns)
            print(f"{path.stem} {pipeline.name}: {name}, {seconds:.0f} s, {words} words, "
                  f"{100 * inside / max(seconds, 1e-9):.0f}% of the time inside the owner's turns")


if __name__ == "__main__":
    main()
