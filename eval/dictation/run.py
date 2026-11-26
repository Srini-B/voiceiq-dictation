#!/usr/bin/env python3
"""Runs the dictation eval the way the app sends a dictation, with every
option on: the prompt comes from the app's own PromptV1.swift (via
eval/promptdump), the Dictionary holds cases.json's terms, the place and
field text are set, and the 1440x900 screen rides along as four JPEGs,
the most ScreenContextCollector keeps. One gemini-3.8-flash call per case,
same body as GeminiClient.dictate.

Writes results/<label>.json with each output, call time and token usage.
Usage: run.py LABEL [--rounds N] [--workers N] [--promptdump PATH]
Needs GEMINI_API_KEY and eval/make_assets.py's output.
"""
import argparse
import base64
import concurrent.futures
import json
import os
import subprocess
import time
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).parent
ASSETS = HERE / ".assets"
MODEL = "gemini-3.8-flash"


def prompt_for(case: dict, spec: dict, promptdump: str, shots: int) -> str:
    request = {"vocabulary": spec["dictionary"], "imagesAttached": shots > 0,
               "app": spec["screen"]["app"], "window": spec["screen"]["window"]}
    if "before" in case:
        request["before"] = case["before"]
    out = subprocess.run([promptdump], input=json.dumps(request).encode(), capture_output=True, check=True)
    return out.stdout.decode()


def call(prompt: str, flac: bytes, screen: bytes, shots: int) -> tuple[str, float, dict]:
    parts = [{"text": prompt}]
    parts += [{"inline_data": {"mime_type": "image/jpeg", "data": base64.b64encode(screen).decode()}}] * shots
    parts.append({"inline_data": {"mime_type": "audio/flac", "data": base64.b64encode(flac).decode()}})
    body = {"contents": [{"role": "user", "parts": parts}],
            "generationConfig": {"temperature": 0, "thinkingConfig": {"thinkingLevel": "low"},
                                 "responseMimeType": "application/json",
                                 "responseJsonSchema": {"type": "object", "properties": {"text": {"type": "string"}},
                                                        "required": ["text"]}}}
    req = urllib.request.Request(
        f"https://generativelanguage.googleapis.com/v1beta/models/{MODEL}:generateContent",
        data=json.dumps(body).encode(),
        headers={"x-goog-api-key": os.environ["GEMINI_API_KEY"], "Content-Type": "application/json"})
    start = time.monotonic()
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                reply = json.loads(r.read())
            break
        except urllib.error.HTTPError as e:
            if e.code != 429 or attempt == 2:
                raise
            time.sleep(10)
    seconds = time.monotonic() - start
    raw = "".join(p.get("text", "") for p in reply["candidates"][0]["content"]["parts"] if not p.get("thought"))
    try:
        text = json.loads(raw)["text"]
    except (ValueError, KeyError):
        text = raw
    if "<<NO_SPEECH>>" in text:
        text = ""
    return text.strip(), seconds, reply.get("usageMetadata", {})


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("label")
    ap.add_argument("--rounds", type=int, default=2)
    ap.add_argument("--workers", type=int, default=3)
    ap.add_argument("--screenshots", type=int, default=4, help="JPEGs attached; 0 = screen context off")
    ap.add_argument("--screen-text", action="store_true",
                    help="experiment: on-screen text (as OCR would read it) in the prompt instead of JPEGs")
    ap.add_argument("--promptdump", default=str(HERE.parent / "promptdump" / "promptdump"))
    args = ap.parse_args()
    if args.screen_text:
        args.screenshots = 0
    spec = json.loads((HERE / "cases.json").read_text())
    screen = (ASSETS / "screen.jpg").read_bytes()
    jobs = [(r, c, prompt_for(c, spec, args.promptdump, args.screenshots)) for r in range(args.rounds) for c in spec["cases"]]
    if args.screen_text:
        ocr = "\n".join([spec["screen"]["window"]] + spec["screen"]["lines"])
        section = ("SCREEN TEXT:\nText read from the user's screen while dictating. Use it only to spell names, identifiers, "
                   "file paths and terms that the speaker actually says; never add screen content that was not spoken, and "
                   "never change a spoken word into a screen word that merely looks similar.\n<screen>\n" + ocr + "\n</screen>")
        jobs = [(r, c, p.replace("\n\nAnswer with a JSON object", "\n\n" + section + "\n\nAnswer with a JSON object"))
                for r, c, p in jobs]
    print(f"{len(jobs)} calls, prompt {len(jobs[0][2])} chars")

    def run(job):
        round_, case, prompt = job
        text, seconds, usage = call(prompt, (ASSETS / f"{case['id']}.flac").read_bytes(), screen, args.screenshots)
        print(f"{case['id']:<18} r{round_} {seconds:5.2f}s thoughts={usage.get('thoughtsTokenCount', 0)}", flush=True)
        return {"id": case["id"], "round": round_, "output": text, "seconds": round(seconds, 3), "usage": usage}

    # A failed call is recorded, not fatal: the paid calls that finished
    # are kept, and the run is marked incomplete so score.py refuses it.
    results, failed = [], []
    with concurrent.futures.ThreadPoolExecutor(args.workers) as pool:
        futures = {pool.submit(run, job): job for job in jobs}
        for future in concurrent.futures.as_completed(futures):
            round_, case, _ = futures[future]
            try:
                results.append(future.result())
            except Exception as error:  # noqa: BLE001 - any failure is recorded per call
                failed.append({"id": case["id"], "round": round_, "error": str(error)})
                print(f"{case['id']:<18} r{round_} FAILED {error}", flush=True)
    results.sort(key=lambda r: (r["round"], r["id"]))
    out = HERE / "results" / f"{args.label}.json"
    out.parent.mkdir(exist_ok=True)
    out.write_text(json.dumps({"label": args.label, "model": MODEL, "prompt_chars": len(jobs[0][2]),
                               "screenshots": args.screenshots, "complete": not failed, "failed": failed,
                               "results": results}, indent=1, ensure_ascii=False))
    print("wrote", out, "" if not failed else f"({len(failed)} calls failed; run incomplete)")


if __name__ == "__main__":
    main()
