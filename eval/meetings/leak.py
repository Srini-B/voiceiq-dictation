#!/usr/bin/env python3
"""How well a prepared meeting's two tracks keep people apart.

A call's mic carries the note owner and its system track carries everyone
else. AMI is recorded in one room, so each headset also hears the others.
For every person this prints how loud they are on the mic track and on the
far-side track, in dB, measured only while they talk alone (a turn of 0.5 s
or more with no other person's turn within 0.3 s). The owner is starred.

Needs ffmpeg. Usage: python3 leak.py DATA_DIR [meeting-id ...]
"""
import array, json, math, os, subprocess, sys

RATE = 8000


def pcm(path):
    out = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-ac", "1", "-ar", str(RATE), "-f", "s16le", "-"],
                         check=True, capture_output=True).stdout
    samples = array.array("h"); samples.frombytes(out)
    return samples


def level(track, spans):
    energy = count = 0
    for start, end in spans:
        part = track[int(start * RATE):int(end * RATE)]
        energy += sum(v * v for v in part); count += len(part)
    return 10 * math.log10(energy / max(1, count) + 1), count / RATE


def main():
    data, only = sys.argv[1], set(sys.argv[2:])
    for name in sorted(os.listdir(data)):
        folder = os.path.join(data, name)
        if name.startswith(".") or (only and name not in only) or not os.path.exists(os.path.join(folder, "reference.json")):
            continue
        ref = json.load(open(os.path.join(folder, "reference.json")))
        turns, owner = ref["segments"], ref["owner"]
        mic, far = pcm(os.path.join(folder, "mic.caf")), pcm(os.path.join(folder, "system.caf"))
        cells = []
        for who in sorted({t["speaker"] for t in turns}):
            others = [(t["start"] - 0.3, t["end"] + 0.3) for t in turns if t["speaker"] != who]
            alone = [(t["start"], t["end"]) for t in turns if t["speaker"] == who and t["end"] - t["start"] >= 0.5
                     and not any(a < t["end"] and t["start"] < b for a, b in others)]
            on_mic, seconds = level(mic, alone)
            on_far, _ = level(far, alone)
            cells.append(f"{who}{'*' if who == owner else ''}: mic {on_mic:.0f}, far {on_far:.0f} ({seconds:.0f} s alone)")
        print(f"{name} | " + " | ".join(cells))


if __name__ == "__main__":
    main()
