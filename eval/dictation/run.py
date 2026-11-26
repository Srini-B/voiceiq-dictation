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
import hashlib
import json
import os
import re
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


def dictation_text(raw: str) -> str | None:
    body = raw.strip()
    if body.startswith("```"):
        body = re.sub(r"^```[a-z]*\s*|\s*```$", "", body)
    try:
        value = json.loads(body)
    except ValueError:
        return None
    return value.get("text") if isinstance(value, dict) and isinstance(value.get("text"), str) else None


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
    # Parsed as GeminiClient.dictate and PromptV1.dictationText parse it: a
    # fenced object is unwrapped, anything that is not {"text": ...} is a
    # malformed answer, which the app sends once more (sendWithRetry).
    start = time.monotonic()
    for answer in range(2):
        for attempt in range(3):
            try:
                with urllib.request.urlopen(req, timeout=120) as r:
                    reply = json.loads(r.read())
                break
            except urllib.error.HTTPError as e:
                if e.code != 429 or attempt == 2:
                    raise
                time.sleep(10)
        raw = "".join(p.get("text", "") for p in reply["candidates"][0]["content"]["parts"] if not p.get("thought"))
        text = dictation_text(raw)
        if text is not None:
            break
    else:
        raise RuntimeError("malformed_answer twice")
    seconds = time.monotonic() - start
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

    # A saved call is reused only when its request was the same: prompt,
    # screenshot count, audio and model, so a label rerun with other
    # settings sends fresh calls instead of relabelling old ones.
    def fingerprint(job):
        _, case, prompt = job
        digest = hashlib.sha256(f"{MODEL}|{args.screenshots}|{prompt}".encode())
        digest.update((ASSETS / f"{case['id']}.flac").read_bytes())
        if args.screenshots:
            digest.update(screen)
        return digest.hexdigest()[:16]

    def run(job):
        round_, case, prompt = job
        text, seconds, usage = call(prompt, (ASSETS / f"{case['id']}.flac").read_bytes(), screen, args.screenshots)
        print(f"{case['id']:<18} r{round_} {seconds:5.2f}s thoughts={usage.get('thoughtsTokenCount', 0)}", flush=True)
        return {"id": case["id"], "round": round_, "request": fingerprint(job), "output": text,
                "seconds": round(seconds, 3), "usage": usage}

    # The result file is rewritten after every call, so an interrupted run
    # keeps what it paid for. A rerun with the same label sends only the
    # calls that have no result yet (failed or never sent). A failure is
    # recorded, and the run stays incomplete, which score.py refuses.
    out = HERE / "results" / f"{args.label}.json"
    out.parent.mkdir(exist_ok=True)
    wanted = {(job[1]["id"], job[0]): fingerprint(job) for job in jobs}
    saved = json.loads(out.read_text())["results"] if out.exists() else []
    results = [r for r in saved if wanted.get((r["id"], r["round"])) == r.get("request")]
    if len(results) < len(saved):
        print(f"{len(saved) - len(results)} saved calls were made with other settings; sending them again")
    done = {(r["id"], r["round"]) for r in results}
    todo = [job for job in jobs if (job[1]["id"], job[0]) not in done]
    if done:
        print(f"{len(done)} calls already done, {len(todo)} to send")
    failed = []

    def save():
        results.sort(key=lambda r: (r["round"], r["id"]))
        # Written aside and renamed over the old file, so a stop mid-write
        # leaves the previous complete file in place.
        part = out.with_suffix(".part")
        part.write_text(json.dumps({"label": args.label, "model": MODEL, "prompt_chars": len(jobs[0][2]),
                                    "screenshots": args.screenshots, "complete": len(results) == len(jobs),
                                    "failed": failed, "results": results}, indent=1, ensure_ascii=False))
        os.replace(part, out)

    with concurrent.futures.ThreadPoolExecutor(args.workers) as pool:
        futures = {pool.submit(run, job): job for job in todo}
        for future in concurrent.futures.as_completed(futures):
            round_, case, _ = futures[future]
            try:
                results.append(future.result())
            except Exception as error:  # noqa: BLE001 - any failure is recorded per call
                failed.append({"id": case["id"], "round": round_, "error": str(error)})
                print(f"{case['id']:<18} r{round_} FAILED {error}", flush=True)
            save()
    save()
    missing = len(jobs) - len(results)
    print("wrote", out, f"({missing} calls without a result; rerun the same command to send them)" if missing else "")

if __name__ == "__main__":
    main()
