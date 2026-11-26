#!/usr/bin/env python3
"""A/B the Gemini dictation prompt of two source trees on the eval corpus.

The prompt is rebuilt from each tree's Swift files (PromptV1.swift, and
DefaultWritingRules.swift when the tree still has it), in the order
PromptV1.dictationPrompt assembles it. Calls alternate between the trees clip
by clip so network and server load hit both alike.

  audio: the recording goes to Gemini (Dictation set to Gemini).
  text:  a Parakeet v3 transcript goes to Gemini (on-device Dictation, writing by Gemini).

python3 eval/names-latency/bench.py --a /tmp/base-src --b . --mode audio --rounds 3 --out x.json
"""
import argparse
import base64
import concurrent.futures
import json
import os
import re
import statistics
import time
import urllib.error
import urllib.request
from pathlib import Path

EVAL_DIR = Path(".amp/in/orb-backup/eval")
HERE = Path(__file__).parent
API_KEY = os.environ["GEMINI_API_KEY"]
MODEL = "gemini-3.8-flash"
OLD_VOCAB = ("Vocabulary — these spellings are authoritative. Replace a similar-sounding or phonetically close "
             "transcription mistake with the exact spelling below when the speech clearly refers to it; do not "
             "force a replacement when the speech clearly means something else:")


def swift_string(src: str, name: str) -> str | None:
    m = re.search(rf'static let {re.escape(name)}\s*=\s*"""\n(.*?)\n(\s*)"""', src, re.S)
    if m:
        indent = m.group(2)
        return "\n".join(l[len(indent):] if l.startswith(indent) else l for l in m.group(1).split("\n"))
    m = re.search(rf'static let {re.escape(name)}\s*=\s*"((?:[^"\\]|\\.)*)"', src)
    if m:
        return m.group(1).replace('\\"', '"').replace("\\(noSpeechToken)", "<<NO_SPEECH>>")
    return None


def prompt_builder(root: str):
    fp = Path(root) / "VoiceIQCore/Sources/FormattingPipeline"
    src = (fp / "PromptV1.swift").read_text()
    rules, examples = swift_string(src, "rules"), swift_string(src, "examples")
    reminder, audio = swift_string(src, "layoutReminder"), swift_string(src, "audioSection")
    intro = swift_string(src, "dictionaryIntro") or OLD_VOCAB
    m = re.search(r'static func transcriptSection\(_ raw: String\) -> String \{\n\s*"(.*?)\\\(raw\)', src, re.S)
    transcript_head = m.group(1).replace("\\n", "\n").replace('\\"', '"')
    m = re.search(r'static let answerFormat = "(.*?)"\n', src)
    answer = m.group(1).replace('\\"', '"').replace("\\(noSpeechToken)", "<<NO_SPEECH>>")
    m = re.search(r'"(SCREEN CONTEXT:\\n.*?)"\)', src)
    screen = m.group(1).replace("\\n", "\n") if m else ""
    dwr = fp / "DefaultWritingRules.swift"
    default_rules = swift_string(dwr.read_text(), "text") if dwr.exists() else None

    screen_intro = swift_string(src, "screenIntro")

    def screen_block(captures):
        seen, lines, used = set(), [], 0
        for line in "\n".join(captures).split("\n"):
            clean = line.replace("<", "‹").replace(">", "›").strip()[:200]
            if not clean or clean in seen:
                continue
            seen.add(clean)
            used += len(clean) + 1
            if used > 6000:
                break
            lines.append(clean)
        return f"{screen_intro}\n<screen>\n" + "\n".join(lines) + "\n</screen>"

    def build(vocabulary, transcript=None, image=False, screen_captures=None):
        sections = [rules]
        if default_rules:
            sections.append("Writing rules from the user (follow these; they refine the rules above):\n"
                            f"<rules>\n{default_rules}\n</rules>")
        if vocabulary:
            sections.append(intro + "\n" + ", ".join(vocabulary[:100]))
        if image:
            sections.append(screen)
        sections += [examples, reminder]
        sections.append(transcript_head + transcript + "\n</raw>" if transcript is not None else audio)
        if screen_captures:
            sections.append(screen_block(screen_captures))
        sections.append(answer)
        return "\n\n".join(sections)
    return build


CACHES = {}
CACHE_SPLIT = "\n\nTHE DICTATION:"


def cached_prefix(prefix):
    """An explicit cachedContents for `prefix`, made once per run."""
    if prefix not in CACHES:
        body = {"model": f"models/{MODEL}", "ttl": "3600s", "contents": [{"role": "user", "parts": [{"text": prefix}]}]}
        req = urllib.request.Request("https://generativelanguage.googleapis.com/v1beta/cachedContents",
                                     data=json.dumps(body).encode(), method="POST",
                                     headers={"Content-Type": "application/json", "x-goog-api-key": API_KEY})
        with urllib.request.urlopen(req, timeout=60) as resp:
            CACHES[prefix] = json.loads(resp.read())["name"]
    return CACHES[prefix]


def call(prompt, flac, images=(), media_resolution=None, cache=False):
    cache_name = None
    if cache and CACHE_SPLIT in prompt:
        prefix, rest = prompt.split(CACHE_SPLIT, 1)
        cache_name, prompt = cached_prefix(prefix), CACHE_SPLIT.lstrip("\n") + rest
    parts = [{"text": prompt}]
    for image in images:
        part = {"inline_data": {"mime_type": "image/jpeg", "data": base64.b64encode(Path(image).read_bytes()).decode()}}
        if media_resolution:
            part["media_resolution"] = {"level": media_resolution}
        parts.append(part)
    if flac:
        parts.append({"inline_data": {"mime_type": "audio/flac", "data": base64.b64encode(Path(flac).read_bytes()).decode()}})
    body = {"contents": [{"role": "user", "parts": parts}],
            "generationConfig": {"temperature": 0, "thinkingConfig": {"thinkingLevel": "low"},
                                 "responseMimeType": "application/json",
                                 "responseJsonSchema": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]}}}
    if cache_name:
        body["cachedContent"] = cache_name
    req = urllib.request.Request(f"https://generativelanguage.googleapis.com/v1beta/models/{MODEL}:generateContent",
                                 data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json", "x-goog-api-key": API_KEY})
    t0 = time.monotonic()
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                raw = json.loads(resp.read())
            break
        except urllib.error.HTTPError as e:
            if e.code in (429, 500, 503) and attempt < 2:
                time.sleep(5)
                t0 = time.monotonic()
                continue
            return {"ok": False, "error": f"http {e.code}", "dt": 0, "text": ""}
    dt = time.monotonic() - t0
    usage = raw.get("usageMetadata", {})
    parts = raw.get("candidates", [{}])[0].get("content", {}).get("parts", [])
    reply = [p.get("text", "") for p in parts if not p.get("thought") and p.get("text", "").strip()]
    try:
        text = json.loads(reply[-1])["text"]
    except Exception:
        return {"ok": False, "error": "bad json", "dt": dt, "text": ""}
    return {"ok": True, "dt": round(dt, 2), "text": "" if "<<NO_SPEECH>>" in text else text,
            "prompt_tokens": usage.get("promptTokenCount", 0), "cached_tokens": usage.get("cachedContentTokenCount", 0),
            "thought_tokens": usage.get("thoughtsTokenCount", 0) or 0}


def hedged(send, after):
    """The first answer of a request and, if it has not answered `after` seconds in, a second one."""
    t0 = time.monotonic()
    pool = concurrent.futures.ThreadPoolExecutor(2)
    first = pool.submit(send)
    done, _ = concurrent.futures.wait([first], timeout=after)
    if done:
        pool.shutdown(wait=False)
        return dict(first.result(), hedged=False)
    second = pool.submit(send)
    done, _ = concurrent.futures.wait([first, second], return_when=concurrent.futures.FIRST_COMPLETED)
    winner = done.pop()
    pool.shutdown(wait=False, cancel_futures=True)
    return dict(winner.result(), dt=round(time.monotonic() - t0, 2), hedged=True)


def score(clip, text):
    has = lambda w: re.search(rf"\b{re.escape(w)}\b", text) is not None
    targets = [t for t in clip.get("targets", []) if t not in ("Thursday", "Friday", "April")]
    s = {"names_total": len(targets) if not clip["category"].startswith("english") else 0,
         "names_hit": 0, "english_total": 0, "english_kept": 0, "flips": [], "keep_miss": [], "eval_ok": True}
    if clip["category"].startswith("english"):
        s["english_total"] = len(targets)
        s["english_kept"] = sum(has(t) for t in targets)
    else:
        s["names_hit"] = sum(has(t) for t in targets)
        s["missed"] = [t for t in targets if not has(t)]
    for bad in clip.get("must_not", []):
        if re.search(rf"\b{re.escape(bad)}\b", text, re.I):
            s["flips"].append(bad)
    for k in clip.get("must_keep", []):
        if k.lower() not in text.lower():
            s["keep_miss"].append(k)
    if clip.get("expect_empty"):
        s["eval_ok"] = text.strip() == ""
    elif clip["category"] in ("contributing", "false_flip", "sound_alike", "text_false_flip", "text_quality"):
        s["eval_ok"] = not s["keep_miss"] and not s["flips"]
    return s


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--a", required=True)
    ap.add_argument("--b", required=True)
    ap.add_argument("--mode", choices=["audio", "text"], default="audio")
    ap.add_argument("--a-mode", choices=["audio", "text"])
    ap.add_argument("--b-mode", choices=["audio", "text"])
    ap.add_argument("--images", default="", help="comma-separated JPEGs sent with every call")
    ap.add_argument("--a-images", default=None)
    ap.add_argument("--b-images", default=None)
    ap.add_argument("--media-resolution", default=None)
    ap.add_argument("--screen-text", default="", help="OCR output file (== headers per capture) sent as SCREEN TEXT")
    ap.add_argument("--screen-variants", default="AB", help="which variants get --screen-text")
    ap.add_argument("--rounds", type=int, default=1)
    ap.add_argument("--only", default="")
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--b-cache", action="store_true", help="B sends the prompt before THE DICTATION as an explicit cache")
    ap.add_argument("--b-hedge", default="", help="B starts a second request after A + speech/B seconds, e.g. 2,20 (the app's hedgeDelay)")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    manifest = json.loads((EVAL_DIR / "manifest.json").read_text())
    clips = manifest["clips"]
    if args.only:
        keep = set(args.only.split(","))
        clips = [c for c in clips if c["category"] in keep or c["id"] in keep]
    modes = {"A": args.a_mode or args.mode, "B": args.b_mode or args.mode}
    heard = json.loads((HERE / "parakeet_transcripts.json").read_text())["none"]
    clips = [dict(c, raw=heard.get(c["id"])) for c in clips]
    if set(modes.values()) == {"text"}:
        clips = [c for c in clips if c["raw"]]
        clips += [dict(c, id=c["id"] + "_eng", raw=c["raw_english"]) for c in json.loads((HERE / "text_cases.json").read_text())]
    builders = {"A": prompt_builder(args.a), "B": prompt_builder(args.b)}
    screen = None
    if args.screen_text:
        captures = Path(args.screen_text).read_text().split("== ")[1:]
        screen = [c.split("\n", 1)[1] for c in captures]
    jobs = [(r, c, v) for r in range(args.rounds) for c in clips for v in ("AB" if (r + len(c["id"])) % 2 else "BA")]

    def run(job):
        r, clip, variant = job
        text = modes[variant] == "text"
        spec = {"A": args.a_images, "B": args.b_images}[variant]
        images = [x for x in (args.images if spec is None else spec).split(",") if x]
        prompt = builders[variant](manifest["dictionary"], clip["raw"] if text else None, bool(images),
                                   screen if variant in args.screen_variants else None)
        send = lambda: call(prompt, None if text else clip["flac"], images, args.media_resolution,
                            cache=variant == "B" and args.b_cache)
        if variant == "B" and args.b_hedge:
            base, per = (float(x) for x in args.b_hedge.split(","))
            res = hedged(send, min(base + clip["duration_s"] / per, 20))
        else:
            res = send()
        return {"round": r, "id": clip["id"], "category": clip["category"], "variant": variant,
                "prompt_chars": len(prompt), **res, **score(clip, res["text"])}

    if args.b_cache:  # made before timing starts, as the app makes it while the user speaks
        cached_prefix(builders["B"](manifest["dictionary"], None, False, None).split(CACHE_SPLIT, 1)[0])
    with concurrent.futures.ThreadPoolExecutor(args.workers) as pool:
        rows = list(pool.map(run, jobs))
    Path(args.out).write_text(json.dumps(rows, indent=1))
    for v in "AB":
        vr = [x for x in rows if x["variant"] == v]
        ok = [x for x in vr if x["ok"]]
        dts = sorted(x["dt"] for x in ok)
        print(f"{v}: prompt {vr[0]['prompt_chars']} chars, {len(ok)}/{len(vr)} ok | latency median {statistics.median(dts):.2f}s "
              f"p90 {dts[int(len(dts) * 0.9) - 1]:.2f}s max {dts[-1]:.2f}s | thinking in {sum(x['thought_tokens'] > 0 for x in ok)} calls, "
              f"{sum(x['thought_tokens'] for x in ok)} tokens | Dictionary names {sum(x['names_hit'] for x in vr)}/{sum(x['names_total'] for x in vr)} "
              f"| English names kept {sum(x['english_kept'] for x in vr)}/{sum(x['english_total'] for x in vr)} "
              f"| flips {sum(len(x['flips']) for x in vr)} | checks failed {sum(not x['eval_ok'] for x in vr)}")


if __name__ == "__main__":
    main()
