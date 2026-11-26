#!/usr/bin/env python3
"""Send-without-reading score for a run.py result.

Method: Voice Arena's Dictation Bench (ZER, AMEND; github.com/VoiceArenaAI/AMEND,
Apache-2.0). Every clip has two references: SPOKEN, the human verbatim
transcript, and INTENDED, what should land on the page. Clips from ASR
corpora have only a verbatim transcript; their INTENDED text is written once
from it by `--intended` and cached, so the judge sees the same reference on
every run. A judge returns the draft with the minimum edits it needs to serve
the INTENDED text's purpose; the edits are counted in code after AMEND's
normalisation (lowercase, sentence punctuation stripped).

  ZER         share of drafts with zero edits (Voice Arena's headline metric)
  send-ready  zero edits AND no formatting fix needed (a question written as
              a statement, a mangled list, a broken email layout, text glued
              together): the bar for sending without reading
  AMEND       pooled character edit rate

Two judges from other providers than the writer where possible: GPT-6 Astra
(OpenAI) and Gemini 4 Argon. A clip counts as zero-edit or send-ready only
when both judges agree; each judge's own score is reported too.

Usage:
  judge.py --intended                 write missing INTENDED texts (cached)
  judge.py results/LABEL.json [...]   judge runs (cached per prompt), print scores
  judge.py results/LABEL.json --misses  also list every clip that needs an edit
"""
import argparse
import concurrent.futures
import hashlib
import json
import os
import re
import unicodedata
import urllib.request
from collections import defaultdict
from pathlib import Path

import jiwer

HERE = Path(__file__).parent
DATA = Path(os.environ.get("HARD_AUDIO_DATA", HERE.parents[1] / ".amp/in/orb-backup/hard"))
CACHE = DATA / "judge-cache.jsonl"
INTENDED = DATA / "intended.json"
JUDGES = ("gpt-6-astra", "gemini-4-argon")

# AMEND v1 judge prompt (Voice Arena, Apache-2.0), with the format question
# and the notes for verbatim corpus references added at the end.
AMEND_BASE = """You are evaluating the output of a dictation tool. You will be given the INTENDED text
(what the user wanted to end up with) and the DRAFT (what the dictation tool produced).

Your job: find what the user would actually have to fix in the DRAFT so that it serves
the same purpose as the INTENDED text, and fix only that, using the fewest possible
word edits. The DRAFT does not need the same wording as the INTENDED text. If a reader
would understand the same thing and act the same way, leave it as it is.

Fix these (they change the meaning, or the user would have to retype them):
- Misrecognized or wrong words ("weight" -> "wait", "offensive" -> "defensive",
  "chronic" -> "cron")
- Missing or extra content of any length. Add anything the INTENDED text says that the
  DRAFT is missing, and delete anything the tool added that is not in the INTENDED text
  (for example an answer it generated, invented content, or repeated text)
- Filler words ("like", "you know", "um", "I mean") that the INTENDED text left out,
  including discourse words at the start of a sentence ("Okay", "OK", "So", "Oh",
  "Well", "Oh, and") when the INTENDED text does not start that sentence with them.
  Only remove fillers: never add a filler or discourse word, even if the INTENDED
  text has one that the DRAFT left out
- Wrong names, including misspelled names, and numbers or dates with the wrong value
  (a different number or date, not the same one written differently)
- Anything that must be written exactly: code identifiers, file names, commands, field
  and config values, versions in code, emails, URLs, and product and proper names.
  Make them match the INTENDED text exactly, including any digits in them
  ("calculate prorated amount" -> "calculateProratedAmount",
  "start date" -> "start_date", "billing ts" -> "billing.ts",
  "PG Bouncer" -> "PgBouncer", "node twenty alpine" -> "node:20-alpine")
- A wrong unit, or an informal/slang unit ("512 megs" -> "512 MB")

Do NOT fix these (same meaning, or only formatting):
- Different wording with the same meaning: articles, singular/plural, tense or
  contraction changes that keep the meaning ("a" vs "the", "note" vs "notes",
  "that handles" vs "that'd handle"), synonyms, paraphrases and word-order changes
  ("I'll mention" vs "I want to mention")
- Small grammar slips and spelling variants that do not change what the reader
  understands: plural vs possessive ("league" vs "league's", "deadlines" vs
  "deadline's"), "they" vs "they'd", "we" vs "we'd", "logs" vs "log", "holiday" vs
  "holidays", and a missing or extra courtesy word ("please")
- Punctuation, capitalization, line breaks, bullets, numbered lists, markdown
- How ordinary numbers are written. Some dictation tools cannot write digits, so
  numbers in words are acceptable, as are digits, decimals vs fractions, and spoken
  separators ("4" vs "four", "$1,450" vs "fourteen fifty", "1.5" vs "1 1/2",
  "$618.40" vs "618 dollars and 40 cents", "10:30 AM" vs "ten thirty AM"). This covers
  amounts, quantities, dates, times, phone numbers, and order, account and ticket
  numbers ("415-555-0147" vs "four one five, five five five, zero one four seven",
  "#ER-3312" vs "ER dash three three one two"), as long as every digit and letter is
  right. A wrong digit is still an error. It does not cover the exact-text items
  above (code, file names, commands, versions in code, emails, URLs, product and
  proper names), where digits must match.
- Standard abbreviations ("tbsp" vs "tablespoons", "lb" vs "pound",
  "mph" vs "miles an hour", "Dr." vs "Doctor")
- Hyphenation and compounding of ordinary words ("short-staffed" vs "short staffed")
- Contractions vs full forms ("we're" vs "we are")
- US vs UK spelling

Rules:
- Leave every part of the DRAFT that does not need fixing exactly as it is.
- When you insert or replace words, match the formatting style of the surrounding
  DRAFT text, including writing numbers as words if the DRAFT does.
- Make each fix as small as possible: replace one word rather than rewriting the
  sentence around it. But fix a missing or extra passage in full.
- If the DRAFT is empty, "fixed" is the INTENDED text.

You are also given SPOKEN: a verbatim transcript of what the user actually said,
including any self-corrections. A self-correction can replace something ("Tuesday,
no wait, Wednesday", "ten AM, sorry, ten thirty", "five times, no, make it three")
or retract something ("get milk and eggs, oh wait, we have eggs, take that off").

Self-corrections are lenient. If a difference between the DRAFT and the INTENDED
text exists only because the DRAFT kept a self-correction from SPOKEN (for example
it kept both the original and the corrected version, kept a retracted item together
with the retraction, or kept cue words such as "no wait", "sorry", "actually no",
"no, make it", "scratch that", "take that off"), leave it unchanged.
It is not an error.

"I mean" is a self-correction cue only when it introduces a correction ("Tuesday,
I mean Wednesday"). Anywhere else ("and I mean, fix every import") it is a filler
and follows the filler rule above.

This takes priority over the rule about extra content. Keep a kept self-correction
whole: the original, the cue words and the correction. This applies even if the cue
words were misheard ("wait now" for "wait no", "no way" for "no wait"). Never delete
only part of it.

But if the DRAFT ends up with the wrong final value, fix it. For example, it kept
"Tuesday" and dropped the correction to "Wednesday", or it mixed the two up.
Everything else follows the normal rules above.
"""

CORPUS_NOTES = """
About these references: SPOKEN is a human transcript of a real recording made by a
speech corpus, often lowercase and unpunctuated, and the speech is spontaneous, so
it can wander or stop mid-thought; INTENDED was written from SPOKEN as the clean
written version. Tamil references spell English loanwords in Tamil script ("க்ளீன்"
for "clean"): in the DRAFT, an English word written in Latin letters, or a Tamil word
in a standard alternative spelling, is the same word and is not an error. A word the
corpus marks as unclear, a name spelled another plausible way when SPOKEN gives no
spelling, and a trailing fragment the speaker abandoned are not errors either.
"""

FORMAT_QUESTION = """
Separately, judge the DRAFT's form as the user would before sending it: would they
have to fix punctuation, capitalization, line breaks or layout because it misleads or
looks broken? Count only real problems: a question written as a statement or the
reverse, sentences run together or split mid-thought so they read wrong, a list or
email layout that is mangled, invented headings or structure the user would delete,
text in the wrong script for the language spoken, or a stray artifact (quotes, labels,
markup). Ordinary style choices are fine.

Respond with JSON: "fixed" holds only the corrected draft text (if no changes are
needed, the DRAFT exactly as given), "format_fix" is true only when such a form
problem exists, and "why" is one short line naming each content fix and form problem
(empty when there are none).

{spoken}<intended>
{intended}
</intended>

<draft>
{draft}
</draft>"""

INTENDED_PROMPT = """Below is a human verbatim transcript of one short recording of someone speaking
(a speech-corpus reference: often lowercase and unpunctuated, with fillers and
restarts). Write the text the speaker would want on the page if this had been a
dictation: the same words and meaning, with fillers ("um", "uh", "you know", "like" as
a pause), stutters, repeated words and abandoned restarts removed, self-corrections
applied, and normal punctuation and capitalization. Do not summarize, paraphrase,
add, or improve anything; keep every content word, name, number and hedge, and keep
the speaker's register. Keep each language as spoken and in the script its reference
uses (Tamil stays in Tamil script). Bracketed corpus tags are not words.

Answer with JSON: {{"intended": "..."}}

<transcript>
{spoken}
</transcript>"""

_QUOTES = str.maketrans({"’": "'", "‘": "'", "“": '"', "”": '"'})
_LEAD = "\"'([{<*_`~•·…—–,;:!?"
_TRAIL = "\"')]}>*_`~•·…—–,;:!?.-"
_JUNK = set(_LEAD) | set(_TRAIL) | set("#")
_ELLIPSIS = re.compile(r"\.{2,}")


def normalize(text: str | None) -> str:
    """AMEND's normalisation.
    >>> normalize("Send it to ops@northwind.io, or visit https://acme.com/docs.")
    'send it to ops@northwind.io or visit https://acme.com/docs'
    """
    if not text:
        return ""
    text = unicodedata.normalize("NFKC", text).translate(_QUOTES).lower()
    out = []
    for token in _ELLIPSIS.sub(" ", text).split():
        token = _ELLIPSIS.sub(" ", token).strip()
        if token and not all(ch in _JUNK for ch in token):
            token = token.lstrip(_LEAD).rstrip(_TRAIL)
            if token:
                out.append(token)
    return " ".join(out)


def char_edits(draft: str, fixed: str) -> tuple[int, int]:
    """
    >>> char_edits("the weight was long", "The wait was long.")
    (3, 17)
    """
    ref, hyp = normalize(fixed), normalize(draft)
    if not ref:
        return len(hyp), 0
    if not hyp:
        return len(ref), len(ref)
    o = jiwer.process_characters(ref, hyp)
    return o.substitutions + o.deletions + o.insertions, o.hits + o.substitutions + o.deletions


def post(url: str, body: dict, headers: dict) -> dict:
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers={"Content-Type": "application/json", **headers})
    with urllib.request.urlopen(req, timeout=600) as r:
        return json.loads(r.read())


def ask(model: str, prompt: str) -> dict:
    """One JSON answer from a judge model, retried on transport errors."""
    last = None
    for _ in range(4):
        try:
            if model.startswith("gemini"):
                reply = post(f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent",
                             {"contents": [{"role": "user", "parts": [{"text": prompt}]}],
                              "generationConfig": {"responseMimeType": "application/json"}},
                             {"x-goog-api-key": os.environ["GEMINI_API_KEY"]})
                parts = reply["candidates"][0]["content"]["parts"]
                text = [p["text"] for p in parts if not p.get("thought") and p.get("text")][-1]
            else:
                reply = post("https://api.openai.com/v1/responses",
                             {"model": model, "input": prompt, "reasoning": {"effort": "medium"},
                              "text": {"format": {"type": "json_object"}}},
                             {"Authorization": f"Bearer {os.environ['OPENAI_API_KEY']}"})
                text = "".join(c["text"] for o in reply["output"] if o["type"] == "message"
                               for c in o["content"] if c["type"] == "output_text")
            return json.loads(re.sub(r"^```(?:json)?\s*|\s*```$", "", text.strip()))
        except Exception as error:  # noqa: BLE001 - retried, then raised
            last = error
    raise RuntimeError(f"{model}: {last}")


class Cache:
    def __init__(self):
        self.items = {}
        if CACHE.exists():
            for line in CACHE.read_text().splitlines():
                k, v = json.loads(line)
                self.items[k] = v

    def get(self, model: str, prompt: str):
        key = hashlib.sha256(f"{model}|{prompt}".encode()).hexdigest()
        if key not in self.items:
            value = ask(model, prompt)
            self.items[key] = value
            with CACHE.open("a") as f:
                f.write(json.dumps([key, value], ensure_ascii=False) + "\n")
        return self.items[key]


def manifest() -> dict:
    return {c["id"]: c for c in map(json.loads, (DATA / "manifest.jsonl").read_text().splitlines())}


def write_intended() -> None:
    have = json.loads(INTENDED.read_text()) if INTENDED.exists() else {}
    todo = [c for c in manifest().values() if not c.get("intended") and c["id"] not in have]
    with concurrent.futures.ThreadPoolExecutor(8) as pool:
        for clip, answer in zip(todo, pool.map(lambda c: ask("gpt-6-astra", INTENDED_PROMPT.format(spoken=c["spoken"])), todo)):
            have[clip["id"]] = answer["intended"]
    INTENDED.write_text(json.dumps(have, indent=1, ensure_ascii=False))
    print(f"{len(todo)} written, {len(have)} cached")


def judge_prompt(clip: dict, intended: str, draft: str) -> str:
    notes = "" if clip.get("intended") else CORPUS_NOTES
    return AMEND_BASE + notes + FORMAT_QUESTION.format(spoken=f"<spoken>\n{clip['spoken']}\n</spoken>\n\n",
                                                       intended=intended, draft=draft)


def judge_run(path: Path, cache: Cache, workers: int) -> list[dict]:
    clips, extra = manifest(), (json.loads(INTENDED.read_text()) if INTENDED.exists() else {})
    run = json.loads(path.read_text())
    rows = []
    for r in run["results"]:
        clip = clips[r["id"]]
        intended = clip.get("intended") or extra.get(r["id"])
        if intended is None:
            raise SystemExit(f"{r['id']}: no INTENDED text; run judge.py --intended first")
        rows.append({"id": r["id"], "stratum": r["stratum"], "draft": r["output"], "seconds": r["seconds"],
                     "usage": r.get("usage", {}), "prompt": judge_prompt(clip, intended, r["output"])})
    jobs = [(row, model) for row in rows for model in JUDGES]
    with concurrent.futures.ThreadPoolExecutor(workers) as pool:
        answers = list(pool.map(lambda job: cache.get(job[1], job[0]["prompt"]), jobs))
    for (row, model), answer in zip(jobs, answers):
        edits, chars = char_edits(row["draft"], answer.get("fixed", ""))
        row.setdefault("judges", {})[model] = {"edits": edits, "chars": chars, "format_fix": bool(answer.get("format_fix")),
                                               "fixed": answer.get("fixed", ""), "why": answer.get("why", "")}
    for row in rows:
        js = row["judges"].values()
        row["zero_edit"] = all(j["edits"] == 0 for j in js)
        row["send_ready"] = all(j["edits"] == 0 and not j["format_fix"] for j in js)
        del row["prompt"]
    return rows


def summary(rows: list[dict]) -> dict:
    def block(rs):
        n = len(rs)
        out = {"n": n, "send_ready": round(100 * sum(r["send_ready"] for r in rs) / n, 1),
               "ZER": round(100 * sum(r["zero_edit"] for r in rs) / n, 1)}
        for m in JUDGES:
            e = sum(r["judges"][m]["edits"] for r in rs); c = sum(r["judges"][m]["chars"] for r in rs)
            out[f"ZER_{m}"] = round(100 * sum(r["judges"][m]["edits"] == 0 for r in rs) / n, 1)
            out[f"AMEND_{m}"] = round(100 * e / max(c, 1), 2)
        return out
    by = defaultdict(list)
    for r in rows:
        by[r["stratum"]].append(r)
    return {"all": block(rows), **{k: block(v) for k, v in sorted(by.items())}}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("runs", nargs="*")
    ap.add_argument("--intended", action="store_true")
    ap.add_argument("--misses", action="store_true")
    ap.add_argument("--workers", type=int, default=12)
    args = ap.parse_args()
    if args.intended:
        write_intended()
    cache = Cache()
    for path in map(Path, args.runs):
        rows = judge_run(path, cache, args.workers)
        scored = path.with_suffix(".judged.json")
        scored.write_text(json.dumps({"summary": summary(rows), "rows": rows}, indent=1, ensure_ascii=False))
        print(path.name)
        for k, v in summary(rows).items():
            print(f"  {k:<16} " + "  ".join(f"{a}={b}" for a, b in v.items()))
        if args.misses:
            for r in rows:
                if not r["send_ready"]:
                    print(f"\n- {r['id']}: {r['draft']!r}")
                    for m, j in r["judges"].items():
                        print(f"    {m}: edits={j['edits']} format_fix={j['format_fix']} {j['why']}")


if __name__ == "__main__":
    main()
