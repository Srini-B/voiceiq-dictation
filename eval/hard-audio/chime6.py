#!/usr/bin/env python3
"""CHiME-6 dev far-field clips: utterances of 3-15 s with 7+ words and at
most 0.5 s of another talker, cut from one Kinect channel (U02 or U04, CH1).
Run after fetch.py. Needs the dev audio and transcriptions under raw/chime6:
  curl -sL .../chimechallenge/chime6/resolve/main/data/CHiME6_transcriptions.tar.gz | tar xz
  curl -sL .../chimechallenge/chime6/resolve/main/data/CHiME6_dev.tar.gz | tar xz --wildcards '*_U02.CH1.wav' '*_U04.CH1.wav'
(https://huggingface.co/datasets; the dev archive is 11 GB, streamed).
"""
import json, os, random, subprocess
from pathlib import Path

HERE = Path(os.environ.get("HARD_AUDIO_DATA", Path(__file__).parents[2] / ".amp/in/orb-backup/hard"))
HERE.mkdir(parents=True, exist_ok=True)
T = HERE / "raw/chime6/CHiME6_transcriptions/transcriptions/transcriptions/dev"
A = HERE / "raw/chime6/CHiME6_dev/CHiME6/audio/dev"
rng = random.Random(6)


def sec(t):
    h, m, s = t.split(":")
    return int(h) * 3600 + int(m) * 60 + float(s)


out = []
for session in ("S02", "S09"):
    utts = json.loads((T / f"{session}.json").read_text())
    spans = [(sec(u["start_time"]), sec(u["end_time"])) for u in utts]
    cands = []
    for i, u in enumerate(utts):
        s, e = spans[i]
        words = u["words"]
        clean = " ".join(w for w in words.split() if not w.startswith("["))
        if not (3 <= e - s <= 15) or len(clean.split()) < 7 or "[inaudible" in words or "[redacted" in words:
            continue
        overlap = sum(max(0, min(b, e) - max(a, s)) for j, (a, b) in enumerate(spans) if j != i)
        if overlap > 0.5:
            continue
        cands.append((u, s, e, clean))
    rng.shuffle(cands)
    for k, (u, s, e, clean) in enumerate(cands[:15]):
        unit = "U02" if k % 2 == 0 else "U04"
        cid = f"chime6_{session}_{unit}_{int(s)}"
        dest = HERE / "clips" / f"{cid}.flac"
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", f"{s - 0.3:.2f}", "-to", f"{e + 0.3:.2f}",
                        "-i", str(A / f"{session}_{unit}.CH1.wav"), "-ac", "1", "-ar", "16000", str(dest)], check=True)
        out.append(dict(id=cid, stratum="chime6", source="chimechallenge/chime6 dev", licence="CC BY 4.0", lang="en",
                        accent="far-field Kinect, dinner party (UK/US English)", duration=round(e - s + 0.6, 2),
                        spoken=clean, intended=None))
print(len(out))
with (HERE / "manifest.jsonl").open("a") as f:
    for r in out:
        f.write(json.dumps(r, ensure_ascii=False) + "\n")
