"""Samples raw dictations from public datasets (inputs only; their cleaned
outputs are never used) and writes data/inputs_public.jsonl.

Audio datasets are read through the Hugging Face datasets-server rows API so
only the transcript text is fetched, never the audio.

usage: python assemble_public.py --out data/inputs_public.jsonl [--seed 7]
"""
import argparse
import csv
import io
import json
import random
import re
import time

import pandas as pd
import requests
from huggingface_hub import hf_hub_download

from common import write_jsonl

p = argparse.ArgumentParser()
p.add_argument("--out", default="data/inputs_public.jsonl")
p.add_argument("--seed", type=int, default=7)
p.add_argument("--scale", type=float, default=1.0, help="multiply every take (for a quick dry run)")
args = p.parse_args()
rng = random.Random(args.seed)

# Name, license, attribution and take, as in the fine-tune plan.
SOURCES = {
    "ductai199x/dictation-to-text": ("CC-BY-SA-4.0", 4500),
    "shantanugoel/aawaaz-transcript-cleanup-dataset": ("MIT", 2500),
    "mohitkrconnect/heed-voice-notes-to-tasks": ("CC-BY-4.0", 2000),
    "nyralabs/disfluency_speech_english": ("Apache-2.0", 1200),
    "tasksource/slurp": ("CC-BY-4.0", 1000),
    "google-research-datasets/disfl_qa": ("CC-BY-4.0", 800),
    "juanquivilla/sotto-transcript-cleanup": ("MIT", 800),
    "hey-lemon/streaming-dictation-asr": ("CC-BY-4.0", 600),
    "ylacombe/podcast_fillers_processed": ("CC-BY-3.0", 600),
    "JacobLinCool/ami-disfluent": ("CC-BY-4.0", 500),
    "deepset/prompt-injections": ("Apache-2.0", 150),
}


def take(name):
    return max(1, int(SOURCES[name][1] * args.scale))


def file(repo, path):
    return hf_hub_download(repo, path, repo_type="dataset")


def rows_api(dataset, config, split, n, filt=lambda r: True, pool=None):
    """Random rows through datasets-server, 100 per request, text columns only."""
    size = requests.get("https://datasets-server.huggingface.co/size", params={"dataset": dataset}, timeout=60).json()
    total = next(s["num_rows"] for s in size["size"]["splits"] if s["config"] == config and s["split"] == split)
    out, seen, tries = [], set(), 0
    while len(out) < (pool or n) and tries < 400:
        tries += 1
        off = rng.randrange(0, max(1, total - 100))
        if off in seen:
            continue
        seen.add(off)
        for attempt in range(5):
            r = requests.get("https://datasets-server.huggingface.co/rows", timeout=60, params=dict(
                dataset=dataset, config=config, split=split, offset=off, length=100))
            if r.status_code == 200:
                break
            time.sleep(2 + attempt * 3)
        else:
            continue
        for row in r.json()["rows"]:
            row = {k: v for k, v in row["row"].items() if k != "audio"}
            if filt(row):
                out.append(row)
    rng.shuffle(out)
    return out[: pool or n]


def words(s):
    return len(s.split())


def rec(source, raw, category, **extra):
    raw = re.sub(r"[ \t]+", " ", raw).strip()
    return dict(source=source, license=SOURCES[source][0], category=category, raw=raw, **extra)


records = []

# ductai199x: Parakeet output of read speech, stratified by its categories.
name = "ductai199x/dictation-to-text"
df = pd.read_parquet(file(name, "data/train-00000-of-00001.parquet"))
df = df[df["dictated"].str.split().str.len().between(3, 450)]
per_cat = take(name) // df["category"].nunique()
for cat, g in df.groupby("category"):
    for _, r in g.sample(min(len(g), per_cat), random_state=args.seed).iterrows():
        vocab = list(r["dictionary"]) if r["dictionary"] is not None and len(r["dictionary"]) else []
        records.append(rec(name, r["dictated"], f"public:{cat}", vocabulary=[str(v) for v in vocab[:30]] or None,
                           text_license=r["license"], source_url=r["source_url"]))

# aawaaz: one file per domain, stratified.
name = "shantanugoel/aawaaz-transcript-cleanup-dataset"
domains = ["academic_research", "casual_conversation", "creative_writing", "email_professional", "financial_business",
           "legal_contract", "medical_clinical", "meeting_notes", "recipe_cooking", "self_corrections_heavy",
           "technical_programming", "travel_logistics"]
from huggingface_hub import list_repo_files
present = {f[:-6] for f in list_repo_files(name, repo_type="dataset") if f.endswith(".jsonl")}
domains = [d for d in domains if d in present] + sorted(present - set(domains))
per = take(name) // len(domains)
for d in domains:
    lines = [json.loads(l) for l in open(file(name, f"{d}.jsonl"))]
    for r in rng.sample(lines, min(per, len(lines))):
        records.append(rec(name, r["input"], f"public:{d}"))

# heed: long rambling notes with several requests; half the plain-text variant.
name = "mohitkrconnect/heed-voice-notes-to-tasks"
lines = [json.loads(l) for l in open(file(name, "data/train.jsonl"))]
for r in rng.sample(lines, take(name)):
    raw = r["note_plain"] if rng.random() < 0.5 and r.get("note_plain") else r["note"]
    records.append(rec(name, raw, "public:long_notes"))

# nyralabs: human verbatim transcripts; hesitation tags become the spoken word.
name = "nyralabs/disfluency_speech_english"


def verbatim(t):
    t = re.sub(r"\[(UH|UM|ER|AH|HM|MM)\]", lambda m: m.group(1).lower(), t, flags=re.I)
    return re.sub(r"\[[^\]]*\]", "", t)


for r in rows_api(name, "default", "train", take(name), lambda r: words(r["verbatim_transcript"]) >= 6):
    records.append(rec(name, verbatim(r["verbatim_transcript"]), "public:disfluent_speech"))

# slurp: spoken commands and questions to an assistant.
name = "tasksource/slurp"
df = pd.read_parquet(file(name, "data/train-00000-of-00001.parquet")).drop_duplicates("sentence1")
for _, r in df.sample(take(name), random_state=args.seed).iterrows():
    records.append(rec(name, r["sentence1"], "public:assistant_command"))

# disfl_qa: corrections inside questions.
name = "google-research-datasets/disfl_qa"
df = pd.read_parquet(file(name, "data/train-00000-of-00001.parquet"))
for _, r in df.sample(take(name), random_state=args.seed).iterrows():
    q = r["disfluent question"]
    records.append(rec(name, q.lower().rstrip("?") if rng.random() < 0.5 else q, "public:question_correction"))

# sotto: short commands and filler look-alikes.
name = "juanquivilla/sotto-transcript-cleanup"
df = pd.read_parquet(file(name, "data/train-00000-of-00001.parquet")).drop_duplicates("input")
for _, r in df.sample(take(name), random_state=args.seed).iterrows():
    records.append(rec(name, r["input"], "public:short"))

# hey-lemon: in-house dictation scripts through many recognizers (CC BY rows only).
name = "hey-lemon/streaming-dictation-asr"
tsv = open(file(name, "outputs/clips/2026-10-21-main.tsv")).read()
rows = [r for r in csv.DictReader(io.StringIO(tsv), delimiter="\t")
        if r["set"].startswith("en-dictation") and r.get("transcript") and words(r["transcript"]) >= 5 and not r.get("error")]
uniq = {r["transcript"].strip(): r for r in rows}
for t, r in rng.sample(sorted(uniq.items()), min(take(name), len(uniq))):
    records.append(rec(name, t, f"public:asr_{r['engine']}"))

# podcast fillers: Whisper output of conversation.
name = "ylacombe/podcast_fillers_processed"
for r in rows_api(name, "CC_BY_3.0", "train", take(name), lambda r: 8 <= words(r["text"]) <= 250):
    records.append(rec(name, r["text"], "public:conversation"))

# AMI: meeting speech, upper case in the source; join a speaker's consecutive turns.
name = "JacobLinCool/ami-disfluent"
rows = rows_api(name, "default", "train", take(name) * 3)
by_speaker = {}
for r in rows:
    by_speaker.setdefault((r["meeting_id"], r["speaker_id"]), []).append(r)
ami = []
for turns in by_speaker.values():
    turns.sort(key=lambda r: r["begin_time"])
    buf = []
    for r in turns:
        buf.append(r["text"].lower())
        if words(" ".join(buf)) >= rng.randint(8, 60):
            ami.append(" ".join(buf))
            buf = []
for t in rng.sample(ami, min(take(name), len(ami))):
    records.append(rec(name, t, "public:meeting"))

# deepset: injection attempts, English only, dictated as-is.
name = "deepset/prompt-injections"
df = pd.read_parquet(file(name, "data/train-00000-of-00001-9564e8b05b4757ab.parquet"))
df = df[(df["label"] == 1) & ~df["text"].str.contains(r"\b(und|die|der|ich|nicht|Sie)\b")]
for _, r in df.sample(min(take(name), len(df)), random_state=args.seed).iterrows():
    records.append(rec(name, r["text"], "public:injection"))

# Recognizer styles: about half of the cased, punctuated inputs become the
# lower-case, unpunctuated style other recognizers produce.
for r in records:
    cased = r["raw"] != r["raw"].lower()
    if cased and rng.random() < 0.4:
        r["raw"] = re.sub(r"[^\w\s'@./:-]|(?<!\w)[.:/-]|[.:/-](?!\w)", "", r["raw"]).lower()
        r["raw"] = re.sub(r"\bi\b", "i", re.sub(r"\s+", " ", r["raw"])).strip()
        r["style"] = "lower"
    else:
        r["style"] = "cased" if cased else "lower"

# About one in six dictations carries a PLACE line, as production sends the
# frontmost app and window title.
PLACES = {
    "chat": [("Slack", "#general"), ("Slack", "Priya Raman (DM)"), ("Messages", "Mom"), ("WhatsApp", "Weekend plans"),
             ("Discord", "#dev-chat"), ("Microsoft Teams", "Design sync")],
    "mail": [("Mail", "Re: Q3 budget review"), ("Google Chrome", "Inbox (3) - Gmail"), ("Outlook", "New Message"),
             ("Spark", "Re: Contract draft")],
    "doc": [("Notes", "Groceries"), ("Notion", "Sprint planning"), ("Google Chrome", "Project brief - Google Docs"),
            ("Pages", "Report draft"), ("Obsidian", "Daily note")],
    "code": [("Xcode", "SettingsView.swift"), ("Cursor", "api/routes.ts"), ("Terminal", "zsh"),
             ("Google Chrome", "Pull Request #212 - GitHub")],
    "ai": [("ChatGPT", "New chat"), ("Claude", "New chat"), ("Google Chrome", "Perplexity")],
}
for r in records:
    if rng.random() < 0.17:
        kind = rng.choice(list(PLACES))
        app, title = rng.choice(PLACES[kind])
        r["place"] = {"app": app, "title": title}

write_jsonl(args.out, records)
from collections import Counter
print(len(records), Counter(r["source"] for r in records))
