#!/usr/bin/env python3
"""Runs the dictation eval the way the app sends a dictation, with every
option on: the prompt comes from the app's own PromptV1.swift (via
eval/promptdump), the Dictionary holds cases.json's terms, the place and
field text are set, and the screen's text goes in the prompt's SCREEN TEXT
section, as ScreenContextCollector reads it with Vision OCR (the window
title and the lines in cases.json, which Vision's accurate recognizer reads
off the 1440x900 screen). One gemini-3.8-flash call per case, same body as
GeminiClient.dictate.

Each call goes out the way GeminiTranscriptionService sends it, with the
app's backup request (DictationHedge): a second request when the first has
not answered after 4-6 s, the first answer winning. usage.secondRequests
counts them.

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
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).parent
ASSETS = HERE / ".assets"
MODEL = "gemini-3.8-flash"


class Hedge:
    """DictationHedge as the app runs it: the second request starts at the
    90th percentile of the last 20 answer times, between 4 and 6 s (6 s
    before five have answered); an answer that needed the second request
    counts as 1.5 times the delay. Shared by the workers like the app's one
    instance is shared by its dictations."""

    def __init__(self, ceiling: float = 6.0):
        self.ceiling = ceiling
        self.recent: list[float] = []
        self.lock = threading.Lock()

    def delay(self) -> float:
        with self.lock:
            if len(self.recent) < 5:
                return min(8.0, self.ceiling)
            ordered = sorted(self.recent)
            return min(max(ordered[int((len(ordered) - 1) * 0.9)], 4.0), self.ceiling)

    def record(self, seconds: float, delay: float) -> None:
        with self.lock:
            self.recent = (self.recent + [delay * 1.5 if seconds > delay else seconds])[-20:]


HEDGE = Hedge()


def first_success(send, delay: float) -> tuple[dict, bool]:
    """GeminiClient.firstSuccess: a second request starts when the first has
    not answered after `delay`; the first answer wins. Returns the reply and
    whether the second request was sent."""
    pool = concurrent.futures.ThreadPoolExecutor(2)
    pending = {pool.submit(send)}
    done, _ = concurrent.futures.wait(pending, timeout=delay)
    second = not done
    if second:
        pending.add(pool.submit(send))
    error = None
    while pending:
        done, pending = concurrent.futures.wait(pending, return_when=concurrent.futures.FIRST_COMPLETED)
        for future in done:
            if future.exception() is None:
                pool.shutdown(wait=False, cancel_futures=True)
                return future.result(), second
            error = future.exception()
    pool.shutdown(wait=False)
    raise error


def prompt_for(case: dict, spec: dict, promptdump: str, screen_on: bool) -> str:
    request = {"vocabulary": spec["dictionary"], "app": spec["screen"]["app"], "window": spec["screen"]["window"]}
    if spec.get("spelling"):
        request["spelling"] = spec["spelling"]
    if screen_on:
        request["screenText"] = ["\n".join([spec["screen"]["window"]] + spec["screen"]["lines"])]
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


def call(prompt: str, flac: bytes) -> tuple[str, float, dict]:
    parts = [{"text": prompt}]
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
    def send() -> dict:
        with urllib.request.urlopen(req, timeout=120) as r:
            return json.loads(r.read())

    # Parsed as GeminiClient.dictate and PromptV1.dictationText parse it: a
    # fenced object is unwrapped, anything that is not {"text": ...} is a
    # malformed answer, which the app sends once more (sendWithRetry).
    start = time.monotonic()
    hedged = 0
    for answer in range(2):
        for attempt in range(3):
            try:
                delay = HEDGE.delay()
                sent = time.monotonic()
                reply, second = first_success(send, delay)
                HEDGE.record(time.monotonic() - sent, delay)
                hedged += second
                break
            except urllib.error.HTTPError as e:
                if e.code != 429 or attempt == 2:
                    raise
                time.sleep(10)
        # As GeminiClient.extractText: the last non-empty, non-thought text
        # part is the answer; an earlier one can be unflagged working.
        texts = [p["text"] for p in reply["candidates"][0].get("content", {}).get("parts", [])
                 if not p.get("thought") and isinstance(p.get("text"), str) and p["text"].strip()]
        raw = texts[-1] if texts else ""
        text = dictation_text(raw)
        if text is not None:
            break
    else:
        raise RuntimeError("malformed_answer twice")
    seconds = time.monotonic() - start
    if "<<NO_SPEECH>>" in text:
        text = ""
    return strip_artifacts(text), seconds, dict(reply.get("usageMetadata", {}), secondRequests=hedged)


def strip_artifacts(text: str) -> str:
    # ValidationGate.stripArtifacts: fences, a leading label, wrapping quotes.
    s = text.strip()
    if s.startswith("```"):
        s = re.sub(r"```[a-z]*\n?", "", s).replace("```", "").strip()
    for label in ("CLEAN:", "Clean:", "Transcript:", "TRANSCRIPT:"):
        if s.startswith(label):
            s = s[len(label):].strip()
    if len(s) > 1 and s.startswith('"') and s.endswith('"'):
        s = s[1:-1]
    return s.strip()


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("label")
    ap.add_argument("--rounds", type=int, default=2)
    ap.add_argument("--workers", type=int, default=3)
    ap.add_argument("--screenshots", type=int, default=4, help="0 = screen context off")
    ap.add_argument("--hedge-ceiling", type=float, default=6.0,
                    help="DictationHedge's ceiling in the commit under test (20 before the follow-up to #83)")
    ap.add_argument("--promptdump", default=str(HERE.parent / "promptdump" / "promptdump"))
    args = ap.parse_args()
    HEDGE.ceiling = args.hedge_ceiling
    spec = json.loads((HERE / "cases.json").read_text())
    jobs = [(r, c, prompt_for(c, spec, args.promptdump, args.screenshots > 0))
            for r in range(args.rounds) for c in spec["cases"]]
    if spec.get("spelling") and spec["spelling"] not in jobs[0][2]:
        raise SystemExit("the prompt has no spelling line: rebuild eval/promptdump (eval/promptdump/build.sh)")
    print(f"{len(jobs)} calls, prompt {len(jobs[0][2])} chars")

    # A saved call is reused only when its request was the same: prompt,
    # screenshot count, audio and model, so a label rerun with other
    # settings sends fresh calls instead of relabelling old ones.
    def fingerprint(job):
        _, case, prompt = job
        digest = hashlib.sha256(f"{MODEL}|{args.screenshots}|{prompt}".encode())
        digest.update((ASSETS / f"{case['id']}.flac").read_bytes())
        return digest.hexdigest()[:16]

    def run(job):
        round_, case, prompt = job
        flac = (ASSETS / f"{case['id']}.flac").read_bytes()
        text, seconds, usage = call(prompt, flac)
        if not text:
            # As the app: an empty answer on real audio is sent once more.
            text, again, retry_usage = call(prompt, flac)
            seconds += again
            usage = dict(retry_usage, secondRequests=usage["secondRequests"] + retry_usage["secondRequests"])
        print(f"{case['id']:<18} r{round_} {seconds:5.2f}s thoughts={usage.get('thoughtsTokenCount', 0)}"
              f"{' hedged' if usage['secondRequests'] else ''}", flush=True)
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
