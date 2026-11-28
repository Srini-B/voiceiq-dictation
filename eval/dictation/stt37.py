#!/usr/bin/env python3
"""Transcribes the dictation eval's clips the way the app does since the
move to AssemblyAI: each clip streams to AssemblyAI-STT-3.7-Realtime in
50 ms PCM chunks at real-time pace, as the microphone would deliver it, and
without keyterms (`--keyterms dictionary` sends the Dictionary, as builds
before the eval of 2026-11-28 did). At the clip's end the script sends
ForceEndpoint, as the app does at key-up, waits for that final turn and
closes the session.

Writes results/<label>.stt.json: per case the joined final turns, the time
from the last audio chunk to the final turn ("tail"), and the session's
billed seconds. writer.py turns these transcripts into written text.

Usage: stt37.py LABEL [--language en|none] [--mode balanced|max_accuracy] [--workers 2]
Needs ASSEMBLYAI_API_KEY, ffmpeg and make_assets.py's output.
Streaming is billed per second of open session ($0.30/hr); free credit covers it.
"""
import argparse
import asyncio
import json
import os
import subprocess
import time
import urllib.parse
from pathlib import Path

import websockets

HERE = Path(__file__).parent
ASSETS = HERE / ".assets"
MODEL = "assemblyai-stt-3-7-realtime"
CHUNK = 1600  # bytes: 800 samples, 50 ms at 16 kHz


def pcm(case_id: str) -> bytes:
    return subprocess.run(["ffmpeg", "-loglevel", "error", "-i", str(ASSETS / f"{case_id}.flac"),
                           "-f", "s16le", "-ac", "1", "-ar", "16000", "-"],
                          capture_output=True, check=True).stdout


async def transcribe(case_id: str, keyterms: list[str], language: str | None, mode: str) -> dict:
    params = {"sample_rate": 16000, "speech_model": MODEL, "mode": mode}
    if keyterms:
        params["keyterms_prompt"] = json.dumps(keyterms[:100])
    if language:
        params["language_codes"] = json.dumps([language])
    url = "wss://streaming.assemblyai.com/v3/ws?" + urllib.parse.urlencode(params)
    audio = pcm(case_id)
    turns: dict[int, str] = {}
    async with websockets.connect(url, additional_headers={"Authorization": os.environ["ASSEMBLYAI_API_KEY"]}) as ws:
        forced = asyncio.Event()
        ended: dict = {}
        tail = {}

        open_turn = {"open": False}

        async def receive():
            async for raw in ws:
                msg = json.loads(raw)
                if msg["type"] == "Turn":
                    open_turn["open"] = not msg.get("end_of_turn")
                if msg["type"] == "Turn" and msg.get("end_of_turn"):
                    turns[msg["turn_order"]] = msg["transcript"]
                    if "sent_force" in tail and "final" not in tail:
                        tail["final"] = time.monotonic()
                        forced.set()
                elif msg["type"] == "Termination":
                    ended.update(msg)
                    return
                elif msg["type"] == "Error" or "error" in msg:
                    raise RuntimeError(msg)

        receiver = asyncio.create_task(receive())
        start = time.monotonic()
        for i in range(0, len(audio), CHUNK):
            await ws.send(audio[i:i + CHUNK])
            # Real-time pace, as a microphone delivers it.
            await asyncio.sleep(max(0.0, start + (i + CHUNK) / 32000 - time.monotonic()))
        tail["sent_force"] = time.monotonic()
        # With every turn already final there is nothing to wait for, as in
        # the app: the session closes at once.
        if open_turn["open"]:
            await ws.send(json.dumps({"type": "ForceEndpoint"}))
            try:
                await asyncio.wait_for(forced.wait(), 3)
            except asyncio.TimeoutError:
                pass
        else:
            tail["final"] = tail["sent_force"]
        await ws.send(json.dumps({"type": "Terminate"}))
        await asyncio.wait_for(receiver, 10)
    text = " ".join(turns[k] for k in sorted(turns) if turns[k].strip())
    return {"id": case_id, "transcript": text,
            "tail": round(tail["final"] - tail["sent_force"], 3) if "final" in tail else None,
            "audio_seconds": round(len(audio) / 32000, 2),
            "session_seconds": ended.get("session_duration_seconds"),
            "billed_audio_seconds": ended.get("audio_duration_seconds")}


async def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("label")
    ap.add_argument("--language", default="en", help="'none' for no steering (native code-switching)")
    ap.add_argument("--mode", default="balanced")
    ap.add_argument("--workers", type=int, default=2)
    ap.add_argument("--only", nargs="*")
    ap.add_argument("--keyterms", choices=["dictionary", "none", "dictionary+screen"], default="none",
                    help="dictionary+screen adds the screen's capitalized words, as the app could send mid-stream")
    args = ap.parse_args()
    spec = json.loads((HERE / "cases.json").read_text())
    cases = [c for c in spec["cases"] if not args.only or c["id"] in args.only]
    language = None if args.language == "none" else args.language
    keyterms = [] if args.keyterms == "none" else list(spec["dictionary"])
    if args.keyterms == "dictionary+screen":
        words = " ".join(spec["screen"]["lines"]).replace(",", " ").split()
        keyterms += [w for w in dict.fromkeys(words) if w[:1].isupper() and w.isalpha() and w not in keyterms]
    out = HERE / "results" / f"{args.label}.stt.json"
    out.parent.mkdir(exist_ok=True)
    done = {r["id"]: r for r in json.loads(out.read_text())["results"]} if out.exists() else {}
    gate = asyncio.Semaphore(args.workers)
    opened: list[float] = []

    async def one(case):
        async with gate:
            # Free tier: 5 new streams a minute.
            while len([t for t in opened if time.monotonic() - t < 60]) >= 5:
                await asyncio.sleep(1)
            opened.append(time.monotonic())
            result = await transcribe(case["id"], keyterms, language, args.mode)
            print(f"{case['id']:<18} tail={result['tail']}s  {result['transcript'][:90]}", flush=True)
            done[case["id"]] = result
            out.write_text(json.dumps({"label": args.label, "model": MODEL, "language": language, "mode": args.mode, "keyterms": args.keyterms,
                                       "results": list(done.values())}, indent=1, ensure_ascii=False))

    await asyncio.gather(*(one(c) for c in cases if c["id"] not in done))
    billed = sum(r.get("session_seconds") or 0 for r in done.values())
    print(f"wrote {out}: {len(done)} cases, {billed:.0f} s of session time (${billed / 3600 * 0.30:.4f})")


if __name__ == "__main__":
    asyncio.run(main())
