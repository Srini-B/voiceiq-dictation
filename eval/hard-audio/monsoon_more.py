#!/usr/bin/env python3
"""Tops monsoon_ta up from the other three Monsoon en-IN shards: speakers
native to Tamil Nadu, 4-30 s, 8+ words, one clip per speaker, up to 60."""
import json, random
from pathlib import Path
import pyarrow.parquet as pq
from fetch import to_flac, audio_bytes, words, hf, MANIFEST

rows = [json.loads(l) for l in MANIFEST.read_text().splitlines()]
have = [r for r in rows if r["stratum"] == "monsoon_ta"]
seen_ids = {r["id"] for r in rows}
rng = random.Random(7)
cand = []
for i in (1, 2, 3):
    t = pq.read_table(hf("VoiceArena/MonsoonASR-Open-ASR-leaderboard-en-IN", f"data/test-0000{i}-of-00004.parquet"),
                      filters=[("native_state", "=", "Tamil Nadu")]).to_pylist()
    cand += [r for r in t if 4.0 <= r["audio_length_s"] <= 30 and words(r["text"]) >= 8]
print("candidates", len(cand))
rng.shuffle(cand)
# Rows written before speaker_id was recorded cannot be checked here.
speakers = {r["speaker_id"] for r in have if "speaker_id" in r}
new = []
for r in cand:
    if len(have) + len(new) >= 60:
        break
    cid = f"mon_{r['id']}"
    if r["speaker_id"] in speakers or cid in seen_ids:
        continue
    speakers.add(r["speaker_id"])
    dur = to_flac(audio_bytes(r["audio"]), cid)
    new.append(dict(id=cid, source="VoiceArena/MonsoonASR-Open-ASR-leaderboard-en-IN", licence="CC BY 4.0", lang="en",
                    accent="Indian English (Tamil Nadu)", duration=dur,
                    device=f"{r['device_manufacturer']} {r['device_model']}", speaker_id=r["speaker_id"],
                    spoken=r["text"], intended=None,
                    stratum="monsoon_ta"))
with MANIFEST.open("a") as f:
    for r in new:
        f.write(json.dumps(r, ensure_ascii=False) + "\n")
print("added", len(new))
