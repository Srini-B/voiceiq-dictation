#!/usr/bin/env python3
"""Writes the dictation eval's STT-3.7 transcripts (stt37.py's output) the
way the app does since the move to AssemblyAI: the app's own PromptV1 in
its transcript mode (built by eval/promptdump, with the Dictionary, place,
field and screen text as run.py sets them) goes to one LLM Gateway chat
completion, which answers {"text": ...}.

Writes results/<label>.json in run.py's format, so score.py scores it.
Each result's "seconds" is the realtime tail (last audio to final
transcript) plus the writer call, the part of key-up to insertion that
the model calls take. usage carries the gateway's token counts and the cost
of the writer call and of the realtime session, in USD.

Usage: writer.py LABEL --stt STT_LABEL --model MODEL [--effort none|low] [--rounds 2] [--via gateway|openrouter]
Needs ASSEMBLYAI_API_KEY with a funded balance (the gateway is not covered by the free
credit), or OPENROUTER_API_KEY with --via openrouter for the same model elsewhere.
"""
import argparse
import concurrent.futures
import json
import os
import subprocess
import time
import urllib.error
import urllib.request
from pathlib import Path

from run import dictation_text

HERE = Path(__file__).parent
GATEWAY = "https://llm-gateway.assemblyai.com/v1/chat/completions"
OPENROUTER = "https://openrouter.ai/api/v1/chat/completions"
# USD per million tokens (in, cached in, out), llm-gateway.assemblyai.com/v1/models, read 2026-11-28.
PRICES = {"gpt-6-luna": (0.10, 0.01, 0.50), "gemini-3.5-flash-lite": (0.30, 0.03, 2.50),
          "gemini-3.8-flash": (0.75, 0.075, 3.75), "claude-haiku-5-5": (0.10, 0.01, 0.50),
          "gemma-4-31b": (0.14, 0.14, 0.40), "gemini-2.5-flash-lite": (0.10, 0.01, 0.40)}
REALTIME_PER_HOUR = 0.30
SCHEMA = {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"],
          "additionalProperties": False}


def prompt_for(case: dict, spec: dict, transcript: str, promptdump: str) -> str:
    request = {"vocabulary": spec["dictionary"], "app": spec["screen"]["app"], "window": spec["screen"]["window"],
               "screenText": ["\n".join([spec["screen"]["window"]] + spec["screen"]["lines"])],
               "transcript": transcript}
    if spec.get("spelling"):
        request["spelling"] = spec["spelling"]
    if "before" in case:
        request["before"] = case["before"]
    out = subprocess.run([promptdump], input=json.dumps(request).encode(), capture_output=True, check=True)
    return out.stdout.decode()


def post(text: str, promptdump: str) -> str:
    """The app's post-processing of the writer's answer (EmailLayout), from its own Swift."""
    out = subprocess.run([promptdump], input=json.dumps({"output": text}).encode(), capture_output=True, check=True)
    return out.stdout.decode()


def call(prompt: str, model: str, effort: str | None, via: str) -> tuple[str, float, dict]:
    body = {"model": model, "messages": [{"role": "user", "content": prompt}], "max_tokens": 4000,
            "response_format": {"type": "json_schema", "json_schema": {"name": "dictation", "strict": True,
                                                                        "schema": SCHEMA}}}
    if via == "openrouter":
        # The same model and request through OpenRouter, for when the gateway
        # is not funded; it reports each call's charge in usage.cost.
        vendor = "google" if model.startswith("gemini") else "openai"
        body["model"] = model if "/" in model else f"{vendor}/{model}"
        body["usage"] = {"include": True}
        if effort:
            body["reasoning"] = {"effort": effort}
        req = urllib.request.Request(OPENROUTER, data=json.dumps(body).encode(), headers={
            "Authorization": f"Bearer {os.environ['OPENROUTER_API_KEY']}", "Content-Type": "application/json"})
    else:
        if effort:
            body["reasoning_effort"] = effort
        req = urllib.request.Request(GATEWAY, data=json.dumps(body).encode(), headers={
            "Authorization": os.environ["ASSEMBLYAI_API_KEY"], "Content-Type": "application/json"})
    for attempt in range(3):
        start = time.monotonic()
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                reply = json.loads(r.read())
            break
        except urllib.error.HTTPError as e:
            detail = e.read().decode()[:300]
            if e.code != 429 and e.code < 500 or attempt == 2:
                raise RuntimeError(f"{e.code} {detail}") from None
            time.sleep(5)
    seconds = time.monotonic() - start
    content = reply["choices"][0]["message"]["content"]
    # As PromptV1.dictationText: the answer is the last {"text": ...} object
    # that ends the reply (a model can repeat it, or write working before it).
    text = dictation_text(content)
    if text is None:
        text = content  # scored as written: a reply that is not the object is a miss the app would retry
    usage = reply.get("usage", {})
    cached = (usage.get("prompt_tokens_details") or {}).get("cached_tokens", 0)
    price_in, price_cached, price_out = PRICES[model.split("/")[-1]]
    cost = ((usage.get("prompt_tokens", 0) - cached) * price_in + cached * price_cached
            + usage.get("completion_tokens", 0) * price_out) / 1e6
    if "cost" in usage:
        cost = usage["cost"]
    return ("" if "<<NO_SPEECH>>" in text else text.strip()), seconds, dict(usage, writer_usd=cost)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("label")
    ap.add_argument("--stt", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--effort")
    ap.add_argument("--via", choices=["gateway", "openrouter"], default="gateway")
    ap.add_argument("--rounds", type=int, default=2)
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--skip", nargs="*", default=[], help="case id prefixes to leave out, such as ml_ta")
    ap.add_argument("--promptdump", default=str(HERE.parent / "promptdump" / "promptdump"))
    args = ap.parse_args()
    spec = json.loads((HERE / "cases.json").read_text())
    stt = {r["id"]: r for r in json.loads((HERE / "results" / f"{args.stt}.stt.json").read_text())["results"]}
    cases = [c for c in spec["cases"] if c["id"] in stt and not c["id"].startswith(tuple(args.skip) or ("\0",))]
    jobs = [(r, c, prompt_for(c, spec, stt[c["id"]]["transcript"], args.promptdump))
            for r in range(args.rounds) for c in cases]
    print(f"{len(jobs)} calls on {args.model}, prompt {len(jobs[0][2])} chars")
    out = HERE / "results" / f"{args.label}.json"
    results, failed = [], []

    def run(job):
        round_, case, prompt = job
        s = stt[case["id"]]
        text, seconds, usage = call(prompt, args.model, args.effort, args.via)
        text = post(text, args.promptdump)
        usage["realtime_usd"] = (s.get("session_seconds") or 0) / 3600 * REALTIME_PER_HOUR
        print(f"{case['id']:<18} r{round_} {seconds:5.2f}s  {text[:80]}", flush=True)
        return {"id": case["id"], "round": round_, "output": text, "seconds": round((s["tail"] or 0) + seconds, 3),
                "writer_seconds": round(seconds, 3), "transcript": s["transcript"], "usage": usage}

    with concurrent.futures.ThreadPoolExecutor(args.workers) as pool:
        futures = {pool.submit(run, job): job for job in jobs}
        for future in concurrent.futures.as_completed(futures):
            round_, case, _ = futures[future]
            try:
                results.append(future.result())
            except Exception as error:  # noqa: BLE001 - recorded per call
                failed.append({"id": case["id"], "round": round_, "error": str(error)})
                print(f"{case['id']:<18} r{round_} FAILED {error}", flush=True)
    results.sort(key=lambda r: (r["round"], r["id"]))
    spent = sum(r["usage"]["writer_usd"] for r in results)
    out.write_text(json.dumps({"label": args.label, "model": f"{args.stt}+{args.model}", "prompt_chars": len(jobs[0][2]),
                               "screenshots": 1, "complete": not failed, "failed": failed, "writer_usd": spent,
                               "results": results}, indent=1, ensure_ascii=False))
    print(f"wrote {out}: {len(results)} calls, {len(failed)} failed, writer ${spent:.4f}")


if __name__ == "__main__":
    main()
