#!/usr/bin/env python3
"""Upstream Hex's words with VoiceiQ's far-side speakers.

Hex writes the far side as one speaker ("Them"). This gives each of Hex's
far-side lines to the person VoiceiQ's speaker model heard for most of it
(LocalMeetingsEval writes those stretches to OUT/far-speakers), so the two
can be scored as one pipeline: Hex's own model and chunking for the words,
pyannote community-1 for who said them. The run time stays Hex's alone; the
speaker model's time is in the hex-speakers outputs (`seconds.speakers`). A line no stretch overlaps takes the
nearest stretch's speaker. Hex gives lines, not word times, so a line that two
people share goes to one of them.

Usage: python3 hex_upstream_speakers.py HEX_OUT_DIR FAR_SPEAKERS_DIR OUT_DIR
"""
import json, os, sys


def speaker(line, stretches):
    overlap = {}
    for s in stretches:
        shared = min(s["end"], line["end"]) - max(s["start"], line["start"])
        if shared > 0:
            overlap[s["speaker"]] = overlap.get(s["speaker"], 0) + shared
    if overlap:
        return max(overlap, key=overlap.get)
    middle = (line["start"] + line["end"]) / 2
    nearest = min(stretches, key=lambda s: min(abs(s["start"] - middle), abs(s["end"] - middle)), default=None)
    return nearest["speaker"] if nearest else 0


def main():
    hex_out, speakers, out = sys.argv[1:4]
    os.makedirs(out, exist_ok=True)
    # Earlier results go first: one whose Hex lines or speaker stretches are gone must not be scored again.
    for name in os.listdir(out):
        if name.endswith(".json"):
            os.remove(os.path.join(out, name))
    for name in sorted(os.listdir(hex_out)):
        stretches_path = os.path.join(speakers, name)
        if not name.endswith(".json") or not os.path.exists(stretches_path):
            continue
        result = json.load(open(os.path.join(hex_out, name)))
        stretches = json.load(open(stretches_path))
        numbers = {}
        for line in result["segments"]:
            if line["speaker_id"] == "you":
                continue
            slot = speaker(line, stretches)
            number = numbers.setdefault(slot, len(numbers) + 1)
            line["speaker_id"], line["speaker_name"] = f"s{number}", f"Speaker {number}"
        result["participants"] = sorted({line["speaker_name"] for line in result["segments"]})
        json.dump(result, open(os.path.join(out, name), "w"), indent=1, ensure_ascii=False)


if __name__ == "__main__":
    main()
