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
not answered after 4-6 s, the first answer winning and the other one
cancelled. Requests stream (alt=sse) as the app's do, so a cancelled one is
billed only if it had already streamed part of its answer.
usage.secondRequests counts backups sent, usage.billedSecondRequests the
billed ones.

Writes results/<label>.json with each output, call time and token usage.
Usage: run.py LABEL [--rounds N] [--workers N] [--promptdump PATH]
Needs GEMINI_API_KEY and eval/make_assets.py's output.
"""
import argparse
import base64
import concurrent.futures
import http.client
import hashlib
import json
import os
import re
import socket
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
    instance is shared by its dictations. A ceiling of 0 is the app since
    2026-11-26: no backup request."""

    def __init__(self, ceiling: float = 0.0):
        self.ceiling = ceiling
        self.recent: list[float] = []
        self.lock = threading.Lock()

    def delay(self) -> float | None:
        if not self.ceiling:
            return None  # concurrent.futures.wait(timeout=None): no backup
        with self.lock:
            if len(self.recent) < 5:
                return min(8.0, self.ceiling)
            ordered = sorted(self.recent)
            return min(max(ordered[int((len(ordered) - 1) * 0.9)], 4.0), self.ceiling)

    def record(self, seconds: float, delay: float | None) -> None:
        if delay is None:
            return
        with self.lock:
            self.recent = (self.recent + [delay * 1.5 if seconds > delay else seconds])[-20:]


HEDGE = Hedge()


def is_connection_failure(error: BaseException) -> bool:
    # GeminiClient.isConnectionFailure: the request never got an HTTP answer.
    return (isinstance(error, (ConnectionError, TimeoutError, http.client.HTTPException))
            or (isinstance(error, urllib.error.URLError) and not isinstance(error, urllib.error.HTTPError)))


def first_success(send, delay: float) -> tuple[dict, bool, list]:
    """GeminiClient.firstSuccess: a second request starts when the first has
    not answered after `delay`, or at once when the first loses its
    connection; the first answer wins and the other request is cancelled.
    Returns the reply, whether the second request was sent, and the
    attempts that did not win as (future, state), for billed_losers()."""
    pool = concurrent.futures.ThreadPoolExecutor(2)
    attempts = [(pool.submit(send, state := {"response": None, "chunks": 0, "cancelled": False}), state)]
    first = attempts[0][0]
    done, _ = concurrent.futures.wait({first}, timeout=delay)
    second = not done or (first.exception() is not None and is_connection_failure(first.exception()))
    if second:
        attempts.append((pool.submit(send, state := {"response": None, "chunks": 0, "cancelled": False}), state))
    pending = {future for future, _ in attempts}
    error = None
    while pending:
        done, pending = concurrent.futures.wait(pending, return_when=concurrent.futures.FIRST_COMPLETED)
        for future in done:
            if future.exception() is None:
                # Every other attempt counts for billing, including one that
                # finished in the same wait; only those still running are cut.
                losers = [(f, state) for f, state in attempts if f is not future]
                for f, state in losers:
                    state["cancelled"] = True
                    if f in pending and state["response"] is not None:
                        abort(state["response"])
                pool.shutdown(wait=False)
                return future.result(), second, losers
            error = future.exception()
    pool.shutdown(wait=False)
    raise error


def abort(response) -> None:
    """Closes a response another thread may be blocked reading, the way the
    app's task cancellation drops the connection."""
    try:
        response.fp.raw._sock.shutdown(socket.SHUT_RDWR)
    except (AttributeError, OSError):
        pass
    response.close()


def billed_losers(losers: list) -> int:
    """Waits for cancelled attempts to wind down and counts those that had
    streamed part of an answer, which Gemini bills; one cancelled before its
    first chunk is not. An attempt still waiting for its response headers
    when it lost is closed as soon as they arrive."""
    concurrent.futures.wait([future for future, _ in losers])
    return sum(state["chunks"] > 0 for _, state in losers)


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
    body = re.sub(r"^```[a-z]*\s*|\s*```$", "", body)
    # As PromptV1.dictationText: the joined stream can carry unflagged
    # working before the answer, so the answer is the last {"text": ...}
    # object that ends the reply.
    for start in reversed([m.start() for m in re.finditer(r'\{\s*"text"\s*:', body)]):
        try:
            value = json.loads(body[start:])
        except ValueError:
            continue
        if isinstance(value, dict) and isinstance(value.get("text"), str):
            return value["text"]
    return None


def joined_event_stream(body: bytes) -> dict:
    """GeminiClient.joinedEventStream: the server-sent events of a streamed
    answer as one generateContent envelope, thought parts left out."""
    text, envelope, candidate = "", {}, {}
    for line in body.decode().splitlines():
        if not line.startswith("data:"):
            continue
        chunk = json.loads(line[5:])
        envelope.update({k: chunk[k] for k in ("usageMetadata", "promptFeedback", "error") if k in chunk})
        first = (chunk.get("candidates") or [{}])[0]
        if "finishReason" in first:
            candidate["finishReason"] = first["finishReason"]
        text += "".join(p.get("text", "") for p in first.get("content", {}).get("parts", []) if not p.get("thought"))
    candidate["content"] = {"parts": [{"text": text}]}
    envelope["candidates"] = [candidate]
    return envelope


class MalformedAnswer(Exception):
    """The reply was not {"text": ...}; the app sends the request once more."""


def call(prompt: str, flac: bytes) -> tuple[str, float, dict]:
    parts = [{"text": prompt}]
    parts.append({"inline_data": {"mime_type": "audio/flac", "data": base64.b64encode(flac).decode()}})
    body = {"contents": [{"role": "user", "parts": parts}],
            "generationConfig": {"temperature": 0, "thinkingConfig": {"thinkingLevel": "low"},
                                 "responseMimeType": "application/json",
                                 "responseJsonSchema": {"type": "object", "properties": {"text": {"type": "string"}},
                                                        "required": ["text"]}}}
    req = urllib.request.Request(
        f"https://generativelanguage.googleapis.com/v1beta/models/{MODEL}:streamGenerateContent?alt=sse",
        data=json.dumps(body).encode(),
        headers={"x-goog-api-key": os.environ["GEMINI_API_KEY"], "Content-Type": "application/json"})
    def send(state: dict) -> tuple[dict, str]:
        # As GeminiClient.dictate: the answer is parsed inside each raced
        # attempt, so a malformed one cannot beat a valid one still running.
        with urllib.request.urlopen(req, timeout=120) as r:
            state["response"] = r
            if state["cancelled"]:
                raise ConnectionAbortedError("lost the race before its answer")
            lines = []
            for line in r:
                lines.append(line)
                state["chunks"] += line.startswith(b"data:")
            reply = joined_event_stream(b"".join(lines))
        if "error" in reply:
            # As GeminiClient.post: an error event after the 200 headers is
            # handled as that status (a 429 waits and sends again).
            raise urllib.error.HTTPError(req.full_url, reply["error"].get("code", 500),
                                         reply["error"].get("message", ""), None, None)
        text = dictation_text(reply["candidates"][0]["content"]["parts"][0]["text"])
        if text is None:
            raise MalformedAnswer()
        return reply, text

    # Parsed as GeminiClient.dictate and PromptV1.dictationText parse it: a
    # fenced object is unwrapped, anything that is not {"text": ...} is a
    # malformed answer, which the app sends once more (sendWithRetry).
    start = time.monotonic()
    hedged = billed_second = 0
    for answer in range(2):
        try:
            for attempt in range(3):
                try:
                    delay = HEDGE.delay()
                    sent = time.monotonic()
                    (reply, text), second, losers = first_success(send, delay)
                    HEDGE.record(time.monotonic() - sent, delay)
                    hedged += second
                    break
                except urllib.error.HTTPError as e:
                    if e.code != 429 or attempt == 2:
                        raise
                    time.sleep(10)
            break
        except MalformedAnswer:
            if answer == 1:
                raise RuntimeError("malformed_answer twice")
    seconds = time.monotonic() - start
    billed_second += billed_losers(losers)
    if "<<NO_SPEECH>>" in text:
        text = ""
    return strip_artifacts(text), seconds, dict(reply.get("usageMetadata", {}), secondRequests=hedged,
                                                billedSecondRequests=billed_second)


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
    ap.add_argument("--hedge-ceiling", type=float, default=0.0,
                    help="DictationHedge's ceiling in the commit under test: 0 = no backup request (the app since"
                         " 2026-11-26), 6 for #95, 20 before the follow-up to #83")
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
    # screenshot count, backup-request ceiling, audio and model, so a label rerun with other
    # settings sends fresh calls instead of relabelling old ones.
    def fingerprint(job):
        _, case, prompt = job
        # "stream": calls made before requests streamed (and losers were
        # cancelled) are not reused or pooled with these.
        digest = hashlib.sha256(f"{MODEL}|stream|{args.screenshots}|hedge{args.hedge_ceiling}|{prompt}".encode())
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
            usage = dict(retry_usage, secondRequests=usage["secondRequests"] + retry_usage["secondRequests"],
                         billedSecondRequests=usage["billedSecondRequests"] + retry_usage["billedSecondRequests"])
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
                                    "screenshots": args.screenshots, "hedge_ceiling": args.hedge_ceiling, "complete": len(results) == len(jobs),
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
