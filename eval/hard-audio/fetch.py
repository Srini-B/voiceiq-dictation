#!/usr/bin/env python3
"""Builds the hard real-human eval set: 16 kHz mono FLAC clips plus
manifest.jsonl with the human reference for each clip.

Strata (cyron speaks English and Tamil, never Hindi):
  va_dictation  Voice Arena Dictation public (US English dictations, spoken+intended), CC BY-NC 4.0
  monsoon_ta    Monsoon en-IN, speakers native to Tamil Nadu (spontaneous, own phones), CC BY 4.0
  monsoon_in    Monsoon en-IN, other Indian states, CC BY 4.0
  indicvoices_ta IndicVoices Tamil validation (conversational Tamil with English words), CC BY 4.0
  svarah        Svarah Indian English, CC BY 4.0
  edacc         EdAcc, spread of English accents (conversational), CC BY-SA 4.0
  whisper       EARS whispered sentences (+ background talkers), CC BY-NC 4.0
  chime6        CHiME-6 dev, far-field Kinect, dinner-party noise, CC BY 4.0  (chime6.py)

Order: fetch.py, then monsoon_more.py (Tamil Nadu speakers from the other
Monsoon shards), then chime6.py.
"""
import hashlib, json, os, random, subprocess, sys, urllib.parse, urllib.request
from pathlib import Path
import pyarrow.parquet as pq

HERE = Path(os.environ.get("HARD_AUDIO_DATA", Path(__file__).parents[2] / ".amp/in/orb-backup/hard"))
HERE.mkdir(parents=True, exist_ok=True)
RAW = HERE / "raw"; RAW.mkdir(exist_ok=True)
CLIPS = HERE / "clips"; CLIPS.mkdir(exist_ok=True)
MANIFEST = HERE / "manifest.jsonl"
rng = random.Random(20261126)


def hf(repo, path):
    dest = RAW / repo.replace("/", "__") / path
    if not dest.exists():
        dest.parent.mkdir(parents=True, exist_ok=True)
        url = f"https://huggingface.co/datasets/{repo}/resolve/main/{path}"
        # Downloaded aside and renamed only when complete, so a failed
        # download is fetched again next time instead of read as cached.
        part = dest.with_name(dest.name + ".part")
        subprocess.run(["curl", "-sfL", "-o", str(part), url], check=True)
        part.replace(dest)
    return dest


def to_flac(data: bytes, cid: str) -> float:
    # Positional IDs (ivta_003, svarah_012) can name another source row after
    # an interrupted fetch, so a cached clip is reused only when it was cut
    # from the same source audio.
    out = CLIPS / f"{cid}.flac"
    source = out.with_suffix(".src")
    digest = hashlib.sha256(data).hexdigest()
    if not out.exists() or not source.exists() or source.read_text() != digest:
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", "pipe:0", "-ac", "1", "-ar", "16000", str(out)],
                       input=data, check=True)
        source.write_text(digest)
    dur = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(out)],
                         capture_output=True, text=True).stdout.strip()
    return round(float(dur), 2)


def audio_bytes(cell):
    if isinstance(cell, dict):
        return cell.get("bytes")
    return cell


rows_out = []
done = set()
if MANIFEST.exists():
    for line in MANIFEST.read_text().splitlines():
        r = json.loads(line); rows_out.append(r); done.add(r["stratum"])


def emit(stratum, items):
    for it in items:
        it["stratum"] = stratum
        rows_out.append(it)
    with MANIFEST.open("w") as f:
        for r in rows_out:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    print(stratum, len(items), flush=True)


def words(s): return len(s.split())


def va_dictation():
    t = pq.read_table(hf("VoiceArena/Dictation_Dataset", "data/test-00000-of-00001.parquet")).to_pylist()
    out = []
    for r in t:
        cid = f"va_{r['id']}"
        dur = to_flac(audio_bytes(r["audio"]), cid)
        out.append(dict(id=cid, source="VoiceArena/Dictation_Dataset", licence="CC BY-NC 4.0", lang="en",
                        accent="US English", domain=r["domain"], duration=dur,
                        spoken=r["spoken_text"], intended=r["intended_text"]))
    return out


def monsoon():
    t = pq.read_table(hf("VoiceArena/MonsoonASR-Open-ASR-leaderboard-en-IN", "data/test-00000-of-00004.parquet")).to_pylist()
    ok = [r for r in t if 4.0 <= r["audio_length_s"] <= 30 and words(r["text"]) >= 8]
    ta = [r for r in ok if r["native_state"] == "Tamil Nadu"]
    other = [r for r in ok if r["native_state"] != "Tamil Nadu"]
    print("monsoon eligible: TN", len(ta), "other", len(other))

    def pick(rows, n):
        # one clip per speaker first, so the set averages over many voices
        rng.shuffle(rows); seen, chosen = set(), []
        for r in rows:
            if r["speaker_id"] not in seen:
                seen.add(r["speaker_id"]); chosen.append(r)
            if len(chosen) == n: break
        return chosen

    res = {}
    for name, rows, n in (("monsoon_ta", ta, 60), ("monsoon_in", other, 60)):
        out = []
        for r in pick(rows, n):
            cid = f"mon_{r['id']}"
            dur = to_flac(audio_bytes(r["audio"]), cid)
            out.append(dict(id=cid, source="VoiceArena/MonsoonASR-Open-ASR-leaderboard-en-IN", licence="CC BY 4.0",
                            lang="en", accent=f"Indian English ({r['native_state']})", duration=dur,
                            device=f"{r['device_manufacturer']} {r['device_model']}", spoken=r["text"], intended=None))
        res[name] = out
    return res


def indicvoices_ta():
    t = pq.read_table(hf("tinisoft/indicvoices-tamil-valid-subset", "data/validation-00000-of-00001.parquet")).to_pylist()
    ok = [r for r in t if 4.0 <= r["duration"] <= 30 and words(r["verbatim"]) >= 6]
    rng.shuffle(ok); seen, out = set(), []
    for r in ok:
        if r["speaker_id"] in seen: continue
        seen.add(r["speaker_id"])
        cid = f"ivta_{len(out):03d}"
        dur = to_flac(audio_bytes(r["audio"]), cid)
        out.append(dict(id=cid, source="ai4bharat/IndicVoices (tinisoft validation subset)", licence="CC BY 4.0",
                        lang="ta", accent=f"Tamil ({r['district']})", scenario=r["scenario"], duration=dur,
                        spoken=r["verbatim"], normalized=r["text"], intended=None))
        if len(out) == 50: break
    return out


def svarah():
    files = json.loads(urllib.request.urlopen("https://huggingface.co/api/datasets/amrithanandini/svarah/tree/main/data").read())
    test = [f["path"] for f in files if "test" in f["path"]]
    t = pq.read_table(hf("amrithanandini/svarah", test[0].removeprefix(""))).to_pylist()
    ok = [r for r in t if 4.0 <= r["duration"] <= 30 and words(r["sentence"]) >= 8]
    rng.shuffle(ok); out = []
    for i, r in enumerate(ok[:40]):
        cid = f"svarah_{i:03d}"
        dur = to_flac(audio_bytes(r["audio"]), cid)
        out.append(dict(id=cid, source="ai4bharat/Svarah (amrithanandini mirror)", licence="CC BY 4.0", lang="en",
                        accent="Indian English", duration=dur, spoken=r["sentence"], intended=None))
    return out


EDACC_QUOTA = {"Indian English": 14, "Nigerian English": 5, "Kenyan English": 5, "Ghanain English": 3,
               "Jamaican English": 4, "Spanish": 4, "Vietnamese": 4, "Chinese": 4, "Italian": 3, "Lithuanian": 3,
               "Romanian": 3, "Irish English": 2, "Scottish English": 2, "Israeli": 2, "Indonesian": 2}


def edacc():
    out = []
    for accent, n in EDACC_QUOTA.items():
        where = urllib.parse.quote(f"\"accent\"='{accent}'")
        cand = []
        for offset in (0, 100, 200):
            url = (f"https://datasets-server.huggingface.co/filter?dataset=edinburghcstr/edacc&config=default"
                   f"&split=test&where={where}&offset={offset}&length=100")
            rows = json.loads(urllib.request.urlopen(url).read()).get("rows", [])
            cand += [r["row"] for r in rows]
            if len(rows) < 100: break
        cand = [r for r in cand if words(r["text"]) >= 10 and "<" not in r["text"]]
        rng.shuffle(cand); seen, k = set(), 0
        for r in cand:
            if r["speaker"] in seen: continue
            src = r["audio"][0]["src"] if isinstance(r["audio"], list) else r["audio"]["src"]
            data = urllib.request.urlopen(src).read()
            cid = f"edacc_{accent.split()[0].lower()}_{k}"
            dur = to_flac(data, cid)
            if not 3.0 <= dur <= 30:
                (CLIPS / f"{cid}.flac").unlink(); continue
            seen.add(r["speaker"]); k += 1
            out.append(dict(id=cid, source="edinburghcstr/edacc", licence="CC BY-SA 4.0", lang="en",
                            accent=f"{accent} ({r['raw_accent']})", duration=dur, spoken=r["text"].lower(), intended=None))
            if k == n: break
    return out


def whisper():
    import csv
    path = hf("Malfaro43/whisperedAudio-benchmark", "benchmark.csv")
    rows = list(csv.DictReader(path.open()))
    out, texts = [], set()
    for t, n_ears, n_expresso in (("2", 4, 10), ("4", 2, 5), ("6", 2, 5)):
        pool = [r for r in rows if r["task"] == t]
        rng.shuffle(pool)
        picked = []
        for r in pool:
            ears = "ears" in r["source"].lower()
            if sum(("ears" in p["source"].lower()) == ears for p in picked) >= (n_ears if ears else n_expresso):
                continue
            if r["text"] in texts and not ears:
                continue
            texts.add(r["text"]); picked.append(r)
        for r in picked:
            data = hf("Malfaro43/whisperedAudio-benchmark", r["audio"]).read_bytes()
            cid = f"whisper_t{t}_{Path(r['audio']).stem}"[:90]
            dur = to_flac(data, cid)
            corpus = "EARS" if "ears" in r["source"].lower() else "Expresso"
            out.append(dict(id=cid, source=f"{corpus} whisper via Malfaro43/whisperedAudio-benchmark ({r['source']})",
                            licence="CC BY-NC 4.0", lang="en",
                            accent="whispered" + ("" if t == "2" else f", two background talkers at {'10' if t=='4' else '25'}%"),
                            duration=dur, spoken=r["text"], intended=None))
    return out


if __name__ == "__main__":
    only = set(sys.argv[1:])
    jobs = [("va_dictation", va_dictation), ("monsoon", monsoon), ("indicvoices_ta", indicvoices_ta),
            ("svarah", svarah), ("edacc", edacc), ("whisper", whisper)]
    for name, fn in jobs:
        if only and name not in only: continue
        if name in done or (name == "monsoon" and "monsoon_ta" in done): continue
        try:
            res = fn()
        except Exception as e:  # noqa: BLE001
            print("FAILED", name, repr(e), flush=True); continue
        if isinstance(res, dict):
            for k, v in res.items(): emit(k, v)
        else:
            emit(name, res)
