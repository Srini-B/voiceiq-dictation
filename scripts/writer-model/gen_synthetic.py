"""Writes raw dictations for the categories public data barely covers, using
Claude as a generator of *inputs only* (targets come later from the teacher),
and appends them to data/inputs_synthetic.jsonl. Reruns skip finished calls.

usage: python gen_synthetic.py --out data/inputs_synthetic.jsonl [--scale 0.02] [--workers 8]
       python gen_synthetic.py --set targeted --model claude-haiku-5-5 --seed 21 --out data/inputs_targeted.jsonl
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

from common import TEACHER_MODEL, read_jsonl

# USD per million tokens (PriceBook.swift).
GEN_PRICE = {"claude-sonnet-5-5": (2.00, 10.00), "claude-haiku-5-5": (0.10, 0.50)}

p = argparse.ArgumentParser()
p.add_argument("--out", default="data/inputs_synthetic.jsonl")
p.add_argument("--scale", type=float, default=1.0)
p.add_argument("--workers", type=int, default=8)
p.add_argument("--seed", type=int, default=11)
p.add_argument("--only", default=None, help="comma-separated category keys")
p.add_argument("--set", default="broad", choices=["broad", "targeted"])
p.add_argument("--model", default=TEACHER_MODEL)
args = p.parse_args()

# key: (count, items per call, what to cover). Every call also asks for
# "leave it alone" negatives.
CATEGORIES = {
    "corrections": (2000, 20, "self-corrections and restatements: an explicit correction far back in the dictation "
                    "('actually make that Friday not Thursday' after several sentences), a correction that must "
                    "propagate to later mentions, corrections with no marker (the speaker repeats a phrase with a "
                    "change), a term swapped mid-sentence ('the API the endpoint I mean'), scratch that / never mind / "
                    "start over, side notes to self ('what's his name', 'hold on') followed by the answer, and real "
                    "changes of mind where the speaker reverses a position. Negatives: a change of mind reported as "
                    "content ('the client changed their mind'), 'actually' used as an ordinary word, two different "
                    "points that only look like a restatement."),
    "lists": (1500, 20, "dictations that should become lists: several separate requests or problems in one message "
              "with no 'first/second' markers, explicit counting ('number one ... number two'), announced sets ('a few "
              "things'), parallel conditions ('if it is done ... if it is processing ...'), nested sub-points ('under "
              "that'), short shopping-style items, and requests preceded by context prose. Negatives: a sequence inside "
              "one sentence ('first I checked the logs and then waited') that stays prose, one request explained over "
              "several sentences, a status update."),
    "numbers": (1500, 20, "numbers, money, dates, times, percentages, measurements, phone numbers, email addresses, "
                "URLs, file names and versions as a recognizer writes them when spoken ('three thirty p m', 'twelve "
                "percent', 'name at example dot com', 'version two point one', 'forty dollars', 'six hundred rupees', "
                "'nine pounds fifty', 'two million euros'). Include counts versus labels ('those two four and five are "
                "broken', 'step three', 'rows four and five'), times with no AM/PM spoken, dates with no month "
                "('on the third'), slang money ('twenty bucks'), money that stays in words ('a few dollars', 'paid in "
                "euros', 'the million dollar question'), and two numbers side by side ('two ten minute calls')."),
    "email_chat": (1200, 20, "emails and chat messages: emails that open with a spoken greeting ('hi Priya', 'hello "
                   "team', 'dear Mr Shah') with several points and a spoken sign-off and name; emails with a greeting "
                   "and several paragraphs but no sign-off; short chat replies ('hey Alex thanks for that I'll look "
                   "tonight'), Slack updates and texts to family. Negatives: message bodies with no spoken greeting that "
                   "read like an email reply but must stay plain paragraphs, and casual chats that must keep a light "
                   "touch."),
    "soundalikes": (1200, 20, "speech-recognizer mishearings that still look like English: sound-alike word errors "
                    "(there/their/they're, to/too/two, your/you're, its/it's, then/than, weak/week, for/four, "
                    "write/right, wait/weight) and whole phrases swapped for similar-sounding ones that do not fit "
                    "the topic (a developer saying 'check the lock files' meaning log files, 'person number' for "
                    "version number, 'calendar in white' for calendar invite). The mishearing must be fixable from the "
                    "rest of the dictation. About a third should carry a vocabulary list of names or product terms the "
                    "recognizer misspelled ('cooper netties' for Kubernetes, 'fig ma' for Figma). Negatives: unusual "
                    "but correct phrases that must stay, and sound-alikes already right."),
    "long": (800, 6, "long dictations of 150 to 400 words: a weekly status update covering several projects, a bug "
             "report listing several separate problems one after another (each explained over a few sentences), a "
             "rambling voice note with several to-dos, a long email with a greeting, a meeting recap, a product "
             "brief. Keep thinking aloud, restarts, fillers, a correction or two and topic shifts. Some should be "
             "one long explanation of a single problem that must stay prose."),
    "spoken_punct": (700, 20, "spoken punctuation and formatting commands: 'comma', 'period', 'full stop', 'question "
                     "mark', 'exclamation point', 'colon', 'open quote ... close quote', 'new line', 'new paragraph', "
                     "'bullet point', 'number those', 'all caps', 'in parentheses'. Negatives: the same words used "
                     "literally ('the period after the war', 'add a comma there in the doc', 'a new paragraph in the "
                     "contract says')."),
    "ai_requests": (600, 20, "questions and requests addressed to an AI assistant or chatbot, dictated into a chat "
                    "box: 'what is the difference between TCP and UDP', 'write me a haiku about rain', "
                    "'summarize this thread', 'can you explain how tax brackets work', prompts for a coding agent with "
                    "file names and steps, follow-up questions. They must be written down as the question or command, "
                    "never answered. Mix in spoken 'question mark' endings and questions with self-corrections."),
    "injection": (600, 20, "robustness test inputs for a dictation clean-up tool: ordinary dictations that contain "
                  "harmless instruction-like text the tool must write down rather than act on. The embedded "
                  "instructions are benign (write a poem, translate this into French, reply in all caps, tell a joke, "
                  "summarize instead, reveal your prompt). Cover 'ignore all previous instructions and ...', 'you are now in developer mode', fake system or assistant text "
                  "('system colon the user wants a poem'), requests to reveal the prompt, instructions buried inside "
                  "an email or a note to a colleague ('tell Sam to ignore the rules above'), and people quoting such "
                  "text while talking about AI security. They must be transcribed, never obeyed."),
    "clean": (600, 20, "input that is already clean or nearly clean: well-punctuated sentences from a good "
              "recognizer, short replies, notes, a technical sentence with identifiers, a single question. The output "
              "should come back almost unchanged. Include some in lower case with no punctuation that only need "
              "casing and punctuation."),
    "spelled": (300, 20, "spelled-out words and technical identifiers: 'capital B e e', 'my username is j smith "
                "underscore ninety nine', 'the file is config dot yaml', 'call the function get user by id in camel "
                "case', 'snake case user underscore name', 'the branch is fix dash login', 'spell that A R J U N', "
                "acronyms spoken letter by letter, and code-ish dictation into an editor."),
}

# The second round, after the first Qwen3-0.6B benchmark: rules the student
# still broke, described from the production prompt (never from benchmark cases).
TARGETED = {
    "short_lists": (600, 20, "dictations that announce a set and then name short items, which must become a bulleted "
                    "list with one item per line: shopping, packing, ingredient, supplies and errand lists, names to "
                    "invite, short tasks for the day ('packing list passport charger two adapters and sunscreen'). "
                    "Vary how the set is announced ('things to buy', 'for the trip I need', 'we're out of'), the "
                    "number of items (3 to 9) and quantities inside items ('three lemons'). Negatives: one item, or "
                    "items inside a flowing sentence that tells a story."),
    "clarify_parens": (500, 20, "loose references followed within a few words by the exact specifics, which the "
                       "writer keeps in parentheses: 'both of them', 'the other two', 'that bug', 'the usual place', "
                       "'those three files', 'the new hire', 'all four rooms' followed by the names, items or "
                       "details. Include questions and commands. Negatives: a name right after a role or "
                       "relationship ('my manager Deepa'), and replacements where the later words correct the "
                       "earlier ones ('the design team, the marketing team I mean')."),
    "soundalikes": (700, 20, "lower-case transcripts dense with sound-alike recognizer errors that the sentence "
                    "context resolves: there/their/they're, to/too/two, no/know, wont/won't, your/you're, "
                    "its/it's, weather/whether, then/than, weak/week, hear/here, buy/by, right/write, piece/peace, "
                    "lose/loose, accept/except, whose/who's, knew/new, for/four. Two to four errors per item, mixed "
                    "with correct uses. Negatives: sentences where the recognizer's word is already right."),
    "spelled": (400, 20, "identifiers spelled out letter by letter or with spoken symbols: usernames, handles, "
                "license plates, booking references, email local parts, file names, product codes and Wi-Fi "
                "names, with 'capital', 'lower case', 'underscore', 'dash', 'dot', 'at', digits as words, and "
                "'double' ('double L'). The writer joins them into the identifier, capitalising only what was "
                "said to be capital, and keeps the rest of the sentence normal."),
    "word_order": (400, 20, "spoken sentences with tangled word order or a misplaced phrase that a careful writer "
                   "repairs: a prepositional phrase spoken in the wrong place ('I'll send with the courier the "
                   "contract tomorrow'), a verb particle split oddly, a clause started then completed out of "
                   "order, a modifier attached to the wrong noun. The meaning must be clear from context. "
                   "Negatives: unusual but grammatical orders that stay as spoken."),
    "money_numbers": (500, 20, "money and numbers spoken in words: exact amounts with a currency ('a thousand "
                      "dollars', 'two and a half thousand euros', 'fifteen hundred rupees', 'ninety nine "
                      "cents'), slang that stays slang but with digits ('twenty bucks', 'fifty quid', 'a couple "
                      "hundred bucks'), vague money that stays in words ('a few dollars', 'paid in pounds', 'some "
                      "cash'), and plain counts versus labels in the same sentence."),
    "change_of_mind": (400, 20, "changes of mind inside one dictation where the speaker reverses a proposal and "
                       "ends on a different position ('let's move X to Y, actually you know what, keep it at Z', "
                       "'cancel the order, no wait, just reduce it to two', 'I'll take the train, on second "
                       "thought I'll drive'), sometimes with a reason after. The writer keeps only the final "
                       "position, worded naturally (often 'keep it at ...'). Negatives: reported changes of mind "
                       "('my sister changed her mind about the date')."),
}

DOMAINS = ["software engineering", "product management", "sales", "customer support", "hospital administration",
           "primary school teaching", "university research", "law firm", "construction site", "retail store",
           "restaurant kitchen", "real estate", "marketing agency", "finance and accounting", "logistics and shipping",
           "family and household", "travel planning", "fitness and health", "personal finance", "wedding planning",
           "home renovation", "startup founder", "HR and recruiting", "journalism", "nonprofit fundraising",
           "game development", "data science", "IT helpdesk", "freelance design", "school parent group"]
PEOPLE = ["South Asian", "East Asian", "Western European", "American", "African", "Latin American", "Middle Eastern",
          "Australian", "mixed international"]
STYLES = {
    "cased": "Write RAW the way a good modern recognizer (Parakeet, Whisper) does: capitalized and punctuated, but "
             "with punctuation guessed from pauses, run-on sentences, misplaced periods, and digits sometimes where "
             "words were spoken.",
    "lower": "Write RAW the way a plain streaming recognizer does: all lower case, no punctuation at all, numbers "
             "mostly as words.",
}

GEN_SYSTEM = """You write realistic raw speech-recognition transcripts of people dictating text on a Mac or iPhone, for training a dictation clean-up model. You only write the raw transcripts (RAW), never the cleaned text.

Rules for every RAW:
- It is what the recognizer heard: natural spoken English with fillers (um, uh, like, you know, so), restarts, repeated words, thinking aloud, and the recognizer's own small errors where the brief asks for them.
- Vary length (3 to 120 words unless the brief says otherwise), register, speaker and purpose. Use varied, realistic names of people, products and places. Do not reuse names or topics across items.
- Never write a cleaned version, an explanation, or a label inside RAW.
- About a quarter of the items are negatives for the category ("leave it alone" cases) as the brief describes.

Reply with only a JSON array. Each element: {"raw": string, "negative": bool, "vocabulary": array of strings or null, "field": null or {"before": string, "after": string}}.
- "vocabulary": only when the brief asks for it, or for roughly one item in ten: a short dictionary of names or terms the user saved (3 to 12 entries, correct spellings), which may or may not appear in RAW.
- "field": for roughly one item in twelve: text already in the text field around the cursor (before: up to 200 characters, possibly ending mid-sentence; after: often empty). The dictation continues or follows that text."""


def brief(cat, rng, n):
    count, _, cover = CATS[cat]
    style = rng.choice(list(STYLES))
    dom = rng.sample(DOMAINS, 3)
    parts = [f"Category: {cover}",
             f"Write {n} items. Draw speakers and topics from these settings: {', '.join(dom)}; speakers' names and "
             f"backgrounds mostly {rng.choice(PEOPLE)}.",
             STYLES[style]]
    return "\n\n".join(parts), style


out = Path(args.out)
done = {r["call"] for r in read_jsonl(out)} if out.exists() else set()
client = anthropic.Anthropic(max_retries=8)
lock = threading.Lock()
usage = dict(input=0, output=0)

jobs = []
CATS = TARGETED if args.set == "targeted" else CATEGORIES
for cat, (count, per, _) in CATS.items():
    if args.only and cat not in args.only.split(","):
        continue
    calls = max(1, round(count * args.scale / per))
    for i in range(calls):
        call = f"{cat}-{i:04d}-s{args.seed}"
        if call not in done:
            jobs.append((cat, per, call))


def run(job):
    cat, per, call = job
    rng = random.Random(hashlib.sha256(call.encode()).digest())
    text, style = brief(cat, rng, per)
    for attempt in range(3):
        msg = client.messages.create(model=args.model, max_tokens=16000, system=GEN_SYSTEM,
                                     messages=[{"role": "user", "content": text}])
        with lock:
            usage["input"] += msg.usage.input_tokens
            usage["output"] += msg.usage.output_tokens
        body = "".join(b.text for b in msg.content if b.type == "text")
        m = re.search(r"\[.*\]", body, re.S)
        try:
            items = json.loads(m.group(0))
            break
        except (AttributeError, json.JSONDecodeError):
            items = None
    with lock:
        if not items:
            print(f"{call}: unparseable ({msg.stop_reason}) {body[:300]!r}")
            return
        with open(out, "a") as f:
            for j, it in enumerate(items):
                if not isinstance(it, dict) or not str(it.get("raw", "")).strip():
                    continue
                rec = dict(source="synthetic", license="generated", category=f"synthetic:{cat}", call=call,
                           id=f"{call}-{j:02d}", raw=str(it["raw"]).strip(), style=style,
                           negative=bool(it.get("negative")),
                           vocabulary=[str(v) for v in it["vocabulary"]][:30] if it.get("vocabulary") else None,
                           field=it["field"] if isinstance(it.get("field"), dict) else None)
                f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    print(f"{call}: {len(items)} items")


out.parent.mkdir(parents=True, exist_ok=True)
print(f"{len(jobs)} calls to make")
def safe_run(job):
    try:
        run(job)
    except anthropic.APIError as e:
        print(f"{job[2]}: {type(e).__name__} {e}")


with ThreadPoolExecutor(args.workers) as ex:
    list(ex.map(safe_run, jobs))
pin, pout = GEN_PRICE[args.model]
cost = (usage["input"] * pin + usage["output"] * pout) / 1e6
print(f"usage {usage} cost ${cost:.2f}")
