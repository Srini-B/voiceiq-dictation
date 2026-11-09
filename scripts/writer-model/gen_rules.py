"""Writes custom-writing-rule profiles and raw dictations for them, using Haiku
as a generator of inputs only (targets come from the teacher, label.py, with
the profile's rules and spelling in the production prompt).

  profiles: a profile is the user's custom rules text and/or an English
            spelling variant, as SettingsStore holds them. Haiku writes rule
            sets per theme; spelling is attached to some of them, and one
            spelling-only profile per variant is added.
  inputs:   per profile, Haiku writes dictations that give some rule something
            to act on, and dictations no rule touches. --pool adds dictations
            from the existing inputs, paired with each profile.

Appends to its outputs and skips finished calls, so a rerun resumes.

usage: python gen_rules.py profiles --out data/rule_profiles.jsonl
       python gen_rules.py inputs --profiles data/rule_profiles.jsonl --out data/inputs_rules.jsonl \
           [--pool data/mlx/all_filtered.jsonl --pool-per 6] [--only p000,p001]
"""
import argparse
import hashlib
import json
import random
import re
import threading
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import anthropic

from common import DOMAINS, GEN_PRICE, GEN_SYSTEM, PEOPLE, SPELLING_VARIANTS, STYLES, read_jsonl, write_jsonl

p = argparse.ArgumentParser()
p.add_argument("step", choices=["profiles", "inputs"])
p.add_argument("--out", required=True)
p.add_argument("--profiles", default="data/rule_profiles.jsonl")
p.add_argument("--model", default="claude-haiku-5-5")
p.add_argument("--set", default="broad", choices=["broad", "format"])
p.add_argument("--prefix", default="p", help="profile id prefix, so a second set's ids stay distinct")
p.add_argument("--per-theme", type=int, default=7)
p.add_argument("--per-profile", type=int, default=28, help="Haiku dictations per rules profile")
p.add_argument("--per-spelling", type=int, default=60, help="Haiku dictations per spelling-only profile")
p.add_argument("--pool", default=None, help="existing inputs to pair with profiles (all_filtered.jsonl)")
p.add_argument("--pool-per", type=int, default=6)
p.add_argument("--only", default=None, help="comma-separated profile ids")
p.add_argument("--workers", type=int, default=8)
p.add_argument("--seed", type=int, default=31)
args = p.parse_args()

# What users put in their custom rules. The owner's examples are seeds, not quotas.
THEMES = {
    "punctuation": "punctuation preferences: the Oxford comma, no exclamation marks, no semicolons, straight or "
                   "curly quotes, a space or none before units, ellipses, ampersands",
    "numbers": "numbers, money, dates, times and units: write numbers under ten as words, always digits, 24-hour "
               "time, a date format (DD/MM/YYYY, 'March 4', ISO), currency symbols or codes, metric abbreviations, "
               "'percent' or '%'",
    "terms": "house vocabulary: 'customers' not 'clients', a team or product name and its exact capitalisation, "
             "words to avoid ('guys', 'utilize', 'just'), a preferred word for a common one, acronyms to expand or "
             "keep",
    "email": "email conventions: a fixed sign-off with the user's name ('Best, Priya'), a greeting style ('Hi "
             "<name>,'), 'Thanks' before the sign-off, no 'Dear', a signature line with a title",
    "lists": "list and layout preferences: lists with dashes, numbered lists for steps, checkboxes for tasks, no "
             "blank lines between list items, bold action items, short paragraphs",
    "tone": "tone and sentence style: keep my sentences short, no contractions, keep it casual, no corporate "
            "phrases, write 'I' not 'we' in status updates, no emoji, avoid passive voice",
    "names": "people and places the user mentions often, with exact spellings and how to refer to them ('my "
             "manager is Deepa Rao, write Deepa', 'our office is in Koramangala'), nicknames to keep",
    "chat": "rules for chat and messaging: lowercase everything in Slack, no full stop at the end of a chat "
            "message, keep messages to one line, write 'np' and 'ty' as the user says them",
    "technical": "rules for technical writing: code identifiers in backticks, snake_case or camelCase for variable "
                 "names, write 'Git' and 'GitHub' with that capitalisation, file paths as typed, version numbers "
                 "with a 'v'",
    "conflicting": "rules that pull against each other or against usual clean-up, mixed with ordinary ones: 'always "
                   "use digits' next to 'numbers under ten as words', 'keep my filler words', 'never make lists', "
                   "'keep everything I say, don't cut anything', 'use British spelling' while the rest are about "
                   "something else",
    "irrelevant": "rules that only matter for one kind of writing the user sometimes does (code reviews, legal "
                  "memos, tweets, recipes, invoices) and that most dictations never trigger, mixed with one general "
                  "rule",
    "mixed": "a realistic mix of three to six unrelated preferences from any of: punctuation, numbers, house terms, "
             "sign-off, list style, tone",
}
# The second set, after the first rules model: rules that rewrite a value
# (a time, a date, a number, a word) were learned per user, not per rule, and
# the model sometimes changed the value while reformatting it. Many users with
# one to three such rules each, a few dictations apiece.
FORMAT_THEMES = {
    "time": "time formats: 24-hour clock, 'am/pm' in lower or upper case, 'noon' and 'midnight' as words, no ':00' "
            "on the hour, a time zone after times",
    "date": "date formats: DD/MM/YYYY, MM/DD/YYYY, ISO 2027-03-04, '4 March 2027', 'March 4th', weekday before the "
            "date, no ordinals",
    "numbers": "number style: numbers under ten (or under 100) as words, always digits, thousands separators or "
               "none, 'percent' or '%', ordinals as words, fractions as words or digits",
    "units_money": "units and money: metric abbreviations (km, kg), currency symbols or codes (₹, £, EUR), 'k' for "
                   "thousands, money with or without cents",
    "words": "word swaps the user always wants: OK not okay, email not e-mail, customers not clients, team or "
             "product names with exact capitalisation, no contractions, 'and' not '&'",
    "layout": "list and message shape: lists with dashes, numbered steps, checkboxes '- [ ] task', a fixed email "
              "sign-off with a name ('Best,\\nPriya'), the Oxford comma, no exclamation marks",
}
FORMATS = [
    "one rule per line, plain sentences",
    "a dashed list ('- rule')",
    "a numbered list",
    "one short paragraph",
    "terse notes, lower case, like a person typing quickly",
    "one rule, a single line",
]
SPELLING_WEIGHTS = {"English (UK)": 4, "English (Australia)": 2, "English (Canada)": 2, "English (India)": 2,
                    "English (US)": 1}

PROFILE_SYSTEM = """You write the custom writing rules that real users type into the settings of a dictation app. The app turns their speech into text, and these rules tell it their personal preferences. Users write them in their own words: some careful, some terse, some with typos or lower case. Rules are about the written result only (spelling, punctuation, numbers, terms, layout, tone, sign-offs), never about the app itself.

Reply with only a JSON array. Each element: {"rules_text": string, "rules": [string, ...]}.
- "rules_text" is exactly what the user typed into the settings box, in the format the brief asks for (keep line breaks as \\n). Under 600 characters, except about one in seven which may run to 1,000.
- "rules" lists the separate rules in "rules_text", one short paraphrase each.
- Never ask for em dashes or en dashes.
- The theme's examples are only examples: vary the wording, and give every user different names, teams, products and places."""

RULES_BRIEF = """The user who is dictating has these custom writing rules in their settings:
<rules>
{rules}
</rules>

Write {n} raw dictations by this user.
- {apply} of them give at least one of the rules above something to act on, naturally (the speaker never mentions the rules). Spread them across the rules; a rule about emails needs an email, a rule about lists needs a list, a rule about a word needs that word.
- The other {skip} are ordinary dictations of the same kinds that none of the rules touches: no list for a list rule, no email for a sign-off rule, no number for a number rule, the avoided word absent or used in a different sense ("client library" for a rule about clients).
Mark each item with "applies": the indexes (0-based) of the rules it triggers, [] for none."""

VALUE_ASK = """Where a rule rewrites a value, use values that are easy to get wrong: afternoon and evening times spoken as "half past four", "quarter to six in the evening" or "three thirty in the afternoon", dates whose day is 12 or less ("March fourth", "the second of June"), years spoken as "twenty twenty seven", amounts with hundreds and thousands, and number words next to digits. Each value must be stated once and clearly, so the right written form is certain."""

PLAIN_BRIEF = """Write {n} raw dictations of every kind: chat messages, emails, notes, lists, status updates, questions. Mark each item with "applies": []."""

SPELLING_ASK = """The user's spelling setting is {variant}. About half of the items contain words whose spelling differs between American and British English (colour, organise, centre, travelling, favourite, licence, catalogue, programme, grey, cheque, defence, analyse, mum, aluminium) or a date. The recognizer writes those words in {source} spelling. Mark those items with "spelling": true."""

ITEM_SYSTEM = GEN_SYSTEM.split("\n- About a quarter")[0] + """

Reply with only a JSON array. Each element: {"raw": string, "applies": [int], "spelling": bool, "vocabulary": array of strings or null, "field": null or {"before": string, "after": string}}.
- "vocabulary": for roughly one item in ten: a short dictionary of names or terms the user saved (3 to 12 entries, correct spellings), which may or may not appear in RAW.
- "field": for roughly one item in twelve: text already in the text field around the cursor (before: up to 200 characters, possibly ending mid-sentence; after: often empty). The dictation continues or follows that text."""

client = anthropic.Anthropic(max_retries=8)
lock = threading.Lock()
usage = dict(input=0, output=0)


def ask(system, text):
    for _ in range(3):
        msg = client.messages.create(model=args.model, max_tokens=16000, system=system,
                                     messages=[{"role": "user", "content": text}])
        with lock:
            usage["input"] += msg.usage.input_tokens
            usage["output"] += msg.usage.output_tokens
        body = "".join(b.text for b in msg.content if b.type == "text")
        m = re.search(r"\[.*\]", body, re.S)
        try:
            return json.loads(m.group(0))
        except (AttributeError, json.JSONDecodeError):
            continue
    return None


def profiles():
    out = Path(args.out)
    have = read_jsonl(out) if out.exists() else []
    done = {r["theme"] for r in have}
    rng = random.Random(args.seed)
    themes = FORMAT_THEMES if args.set == "format" else THEMES

    fmts = {t: [rng.choice(FORMATS) for _ in range(args.per_theme)] for t in themes}

    def run(theme):
        size = "1 to 3 rules" if args.set == "format" else "1 to 5 rules (mostly 2 to 4)"
        text = (f"Theme: {themes[theme]}\n\nWrite {args.per_theme} different users' rule boxes, each with {size}. "
                f"Formats, in order: {'; '.join(fmts[theme])}.")
        try:
            items = ask(PROFILE_SYSTEM, text) or []
        except Exception as e:  # saved themes stay saved; this one is retried on the next run
            print(f"{theme}: {e}")
            items = []
        return theme, [it for it in items if isinstance(it, dict) and str(it.get("rules_text", "")).strip()]

    with ThreadPoolExecutor(args.workers) as ex:
        results = list(ex.map(run, [t for t in themes if t not in done]))
    rows = list(have)
    for theme, items in sorted(results):
        for j, it in enumerate(items):
            spelling = None
            if rng.random() < 0.35:
                spelling = rng.choices(list(SPELLING_WEIGHTS), weights=list(SPELLING_WEIGHTS.values()))[0]
            rows.append(dict(theme=theme, rules=str(it["rules_text"]).strip(), rule_list=it.get("rules") or [],
                             spelling=spelling))
    # Users who keep many rules: three or four other users' boxes joined.
    boxes = [r for r in rows if r["theme"] in THEMES]
    if args.set == "broad" and "long" not in done and len(boxes) >= 4:  # else on a later run
        for _ in range(6):
            picks = rng.sample(boxes, rng.choice([3, 4]))
            rows.append(dict(theme="long", rules="\n".join(r["rules"] for r in picks),
                             rule_list=[x for r in picks for x in r["rule_list"]],
                             spelling=rng.choice([None, None, "English (UK)"])))
    if args.set == "broad" and "spelling" not in done:
        rows += [dict(theme="spelling", rules=None, rule_list=[], spelling=s) for s in SPELLING_VARIANTS]
    for i, r in enumerate(rows):
        r["profile"] = f"{args.prefix}{i:03d}"
    write_jsonl(out, rows)
    print(f"{len(rows)} profiles")


def inputs():
    profs = read_jsonl(args.profiles)
    if args.only:
        keep = set(args.only.split(","))
        profs = [p for p in profs if p["profile"] in keep]
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    have = read_jsonl(out) if out.exists() else []
    done = {r["call"] for r in have if "call" in r}  # --pool rows have none

    def run(prof):
        call = f"{prof['profile']}-s{args.seed}"
        if call in done:
            return
        rng = random.Random(hashlib.sha256(call.encode()).digest())
        spelling = prof.get("spelling")
        if prof["rules"]:
            n = args.per_profile
            share = 0.8 if args.set == "format" else 0.65
            parts = [RULES_BRIEF.format(rules=prof["rules"], n=n, apply=round(n * share), skip=n - round(n * share))]
            if args.set == "format":
                parts.append(VALUE_ASK)
        else:
            parts = [PLAIN_BRIEF.format(n=args.per_spelling)]
        if spelling:
            parts.append(SPELLING_ASK.format(variant=spelling,
                                             source="British" if spelling == "English (US)" else "American"))
        style = rng.choice(list(STYLES))
        parts += [f"Draw speakers and topics from these settings: {', '.join(rng.sample(DOMAINS, 3))}; names mostly "
                  f"{rng.choice(PEOPLE)}.", STYLES[style]]
        text = "\n\n".join(parts)
        items = ask(ITEM_SYSTEM, text)
        if not items:
            print(f"{call}: unparseable")
            return
        with lock, open(out, "a") as f:
            for j, it in enumerate(items):
                if not isinstance(it, dict) or not str(it.get("raw", "")).strip():
                    continue
                rec = dict(source="synthetic", license="generated", category=f"rules:{prof['theme']}",
                           call=call, id=f"{call}-{j:02d}", profile=prof["profile"], raw=str(it["raw"]).strip(),
                           style=style, rules=prof["rules"], spelling=spelling,
                           applies=[a for a in it.get("applies") or [] if isinstance(a, int)],
                           spelling_words=bool(it.get("spelling")),
                           vocabulary=[str(v) for v in it["vocabulary"]][:30] if it.get("vocabulary") else None,
                           field=it["field"] if isinstance(it.get("field"), dict) else None)
                f.write(json.dumps(rec, ensure_ascii=False) + "\n")
        print(f"{call}: {len(items)} items")

    def safe(prof):
        try:
            run(prof)
        except anthropic.APIError as e:
            print(f"{prof['profile']}: {type(e).__name__} {e}")

    with ThreadPoolExecutor(args.workers) as ex:
        list(ex.map(safe, profs))

    if args.pool:
        # Existing inputs (train split only) under each profile: mostly
        # dictations no rule touches, labelled again with the rules in place.
        have_ids = {r["id"] for r in read_jsonl(out)}
        pool = [r for r in read_jsonl(args.pool) if r.get("split") == "train"]
        rng = random.Random(args.seed)
        with open(out, "a") as f:
            for prof in profs:
                k = args.pool_per if prof["rules"] else args.pool_per * 3
                for src in rng.sample(pool, k):
                    rid = f"{prof['profile']}-pool-{src['id']}"
                    if rid in have_ids:
                        continue
                    rec = {key: src.get(key) for key in ("source", "license", "raw", "vocabulary", "place", "field")}
                    rec.update(category=f"rules:{prof['theme']}:pool", id=rid, profile=prof["profile"],
                               rules=prof["rules"], spelling=prof.get("spelling"), applies=None)
                    f.write(json.dumps(rec, ensure_ascii=False) + "\n")


if args.step == "profiles":
    profiles()
else:
    inputs()
pin, pout = GEN_PRICE[args.model]
print(f"usage {usage} cost ${(usage['input'] * pin + usage['output'] * pout) / 1e6:.3f}")
