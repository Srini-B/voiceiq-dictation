#!/usr/bin/env python3
"""Runs the hard real-human set through the app's Gemini dictation request
with every option on: the prompt the app builds (eval/promptdump), the
Dictionary and English (India) spelling line from eval/dictation/cases.json,
a place that fits the clip, and the screen's text. The request, backup
request, retries and artifact stripping are eval/dictation/run.py's copy of
GeminiClient.dictate.

Usage: run.py LABEL [--manifest PATH] [--clips DIR] [--workers N] [--only STRATUM,...]
Writes results/<LABEL>.json, saved after every call; rerunning the same
label sends only the missing calls.
"""
import argparse
import concurrent.futures
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).parent
sys.path.insert(0, str(HERE.parent / "dictation"))
import run as app  # noqa: E402  eval/dictation/run.py: the app's request

DATA = Path(os.environ.get("HARD_AUDIO_DATA", HERE.parents[1] / ".amp/in/orb-backup/hard"))
SPEC = json.loads((HERE.parent / "dictation" / "cases.json").read_text())

# Where a dictation of each kind usually lands.
PLACES = {
    "email": ("Mail", "Inbox – New Message"),
    "work_chat": ("Slack", SPEC["screen"]["window"]),
    "personal_messaging": ("WhatsApp", "WhatsApp"),
    "code": ("Cursor", "dictation.swift — voiceiq-dictation"),
    "ai_prompt": ("ChatGPT", "ChatGPT"),
    "docs_notes": ("Notes", "Notes"),
    "long_form": ("Google Docs", "Untitled document - Google Docs"),
}


def prompt_for(clip: dict, promptdump: str, transcript: str | None = None) -> str:
    app_name, window = PLACES.get(clip.get("domain"), ("WhatsApp" if clip["lang"] == "ta" else "Slack",
                                                        "WhatsApp" if clip["lang"] == "ta" else SPEC["screen"]["window"]))
    screen = [window] + (SPEC["screen"]["lines"] if app_name == "Slack" else [])
    request = {"vocabulary": SPEC["dictionary"], "spelling": SPEC["spelling"], "app": app_name, "window": window,
               "screenText": ["\n".join(screen)]}
    if transcript is not None:
        request["transcript"] = transcript
    out = subprocess.run([promptdump], input=json.dumps(request).encode(), capture_output=True, check=True)
    return out.stdout.decode()


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("label")
    ap.add_argument("--manifest", default=str(DATA / "manifest.jsonl"))
    ap.add_argument("--clips", default=str(DATA / "clips"))
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--only", default="")
    ap.add_argument("--promptdump", default=str(HERE.parent / "promptdump" / "promptdump"))
    ap.add_argument("--ondevice", help="ondevice/ output JSON: Gemini writes these transcripts, sent as text")
    args = ap.parse_args()
    clips = [json.loads(line) for line in Path(args.manifest).read_text().splitlines()]
    if args.only:
        clips = [c for c in clips if c["stratum"] in args.only.split(",")]
    heard = json.loads(Path(args.ondevice).read_text())["texts"] if args.ondevice else None
    if heard is not None:
        clips = [c for c in clips if c["id"] in heard]
    jobs = [(c, prompt_for(c, args.promptdump, heard[c["id"]] if heard else None)) for c in clips]

    def fingerprint(job, audio):
        digest = hashlib.sha256(f"{app.MODEL}|{job[1]}".encode())
        digest.update(audio)
        return digest.hexdigest()[:16]

    def audio_of(clip):
        return (Path(args.clips) / f"{clip['id']}.flac").read_bytes()

    out = HERE / "results" / f"{args.label}.json"
    out.parent.mkdir(exist_ok=True)
    wanted = {job[0]["id"]: fingerprint(job, audio_of(job[0])) for job in jobs}
    saved = json.loads(out.read_text())["results"] if out.exists() else []
    # Saving replaces the label's file, so clips outside this selection would be
    # dropped and paid for again on the next full run.
    outside = sorted({r["id"] for r in saved} - set(wanted))
    if outside:
        raise SystemExit(f"{out} holds {len(outside)} clips outside this selection; use another --label")
    results = [r for r in saved if wanted.get(r["id"]) == r["request"]]
    done = {r["id"] for r in results}
    todo = [job for job in jobs if job[0]["id"] not in done]
    print(f"{len(jobs)} clips, {len(done)} done, {len(todo)} to send", flush=True)
    failed = []

    def run(job):
        clip, prompt = job
        audio = audio_of(clip)
        flac = None if heard is not None else audio
        text, seconds, usage = app.call(prompt, flac)
        if not text:
            text, again, retry = app.call(prompt, flac)
            seconds += again
            usage = dict(retry, secondRequests=usage["secondRequests"] + retry["secondRequests"])
        return {"id": clip["id"], "stratum": clip["stratum"], "request": fingerprint(job, audio), "output": text,
                "seconds": round(seconds, 3), "usage": usage}

    def save():
        results.sort(key=lambda r: r["id"])
        part = out.with_suffix(".part")
        part.write_text(json.dumps({"label": args.label, "model": app.MODEL, "complete": len(results) == len(jobs),
                                    "failed": failed, "results": results}, indent=1, ensure_ascii=False))
        os.replace(part, out)

    with concurrent.futures.ThreadPoolExecutor(args.workers) as pool:
        futures = {pool.submit(run, job): job for job in todo}
        for future in concurrent.futures.as_completed(futures):
            clip = futures[future][0]
            try:
                r = future.result()
                results.append(r)
                print(f"{clip['id'][:40]:<40} {r['seconds']:5.2f}s", flush=True)
            except Exception as error:  # noqa: BLE001 - recorded per call
                failed.append({"id": clip["id"], "error": str(error)})
                print(f"{clip['id']} FAILED {error}", flush=True)
            save()
    save()
    print("wrote", out)


if __name__ == "__main__":
    main()
