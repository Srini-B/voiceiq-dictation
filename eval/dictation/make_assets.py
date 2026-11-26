#!/usr/bin/env python3
"""Builds the dictation eval's audio and screen context from cases.json.

Audio: OpenAI TTS (gpt-4o-mini-tts) speaks each case, then ffmpeg makes the
16 kHz mono FLAC the app sends. Cases marked "noisy" are sped up 12%,
band-limited to a laptop mic and mixed with pink noise. The screen is a
1440x900 chat window holding the screen-only names, saved as the app's
JPEG (longest side 1280, quality 60).

Needs OPENAI_API_KEY, ffmpeg and ImageMagick. Output goes to
eval/dictation/.assets/ (git-ignored); a clip is kept only while its text,
voice and noise are unchanged.
"""
import json
import os
import subprocess
import urllib.request
from pathlib import Path

HERE = Path(__file__).parent
ASSETS = HERE / ".assets"
VOICE_NAMES = {"in": "ash", "us": "coral", "native": "sage", "literal": "coral"}


def tts(text: str, instructions: str, voice: str, out: Path) -> None:
    body = json.dumps({"model": "gpt-4o-mini-tts", "voice": voice, "input": text,
                       "instructions": instructions, "response_format": "wav"}).encode()
    req = urllib.request.Request("https://api.openai.com/v1/audio/speech", data=body, headers={
        "Authorization": f"Bearer {os.environ['OPENAI_API_KEY']}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as r:
        out.write_bytes(r.read())


def ffmpeg(*args: str) -> None:
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", *args], check=True)


def make_audio(spec: dict) -> None:
    for case in spec["cases"]:
        flac = ASSETS / f"{case['id']}.flac"
        # A clip is reused only when it was made from the same text, voice
        # and noise; any change, or a clip with no record, is made again.
        made_from = ASSETS / f"{case['id']}.made-from.json"
        inputs = json.dumps({"text": case["text"], "voice": VOICE_NAMES[case["voice"]],
                             "instructions": spec["voices"][case["voice"]], "noisy": bool(case.get("noisy"))},
                            sort_keys=True, ensure_ascii=False)
        if flac.exists() and made_from.exists() and made_from.read_text() == inputs:
            continue
        wav = ASSETS / f"{case['id']}.wav"
        # Written under a temporary name and renamed when ffmpeg succeeds, so
        # an interrupted run never leaves a cut-off FLAC that later runs reuse.
        part = ASSETS / f"{case['id']}.part.flac"
        tts(case["text"], spec["voices"][case["voice"]], VOICE_NAMES[case["voice"]], wav)
        if case.get("noisy"):
            ffmpeg("-i", wav.as_posix(), "-f", "lavfi", "-i", "anoisesrc=color=pink:amplitude=0.03",
                   "-filter_complex", "[0]atempo=1.12,highpass=f=200,lowpass=f=3800[v];[v][1]amix=inputs=2:duration=first",
                   "-ar", "16000", "-ac", "1", "-c:a", "flac", part.as_posix())
        else:
            ffmpeg("-i", wav.as_posix(), "-ar", "16000", "-ac", "1", "-c:a", "flac", part.as_posix())
        part.rename(flac)
        made_from.write_text(inputs)
        wav.unlink()
        print("audio", case["id"])


def make_screen(spec: dict) -> None:
    jpg = ASSETS / "screen.jpg"
    if jpg.exists():
        return
    screen = spec["screen"]
    text = "\n\n".join(screen["lines"]).replace("'", "\u2019")
    png = ASSETS / "screen.png"
    subprocess.run(["magick", "-size", "1440x900", "xc:#1d1f23", "-fill", "#2b2d31", "-draw", "rectangle 0,0 260,900",
                    "-fill", "#e8e8e8", "-font", "DejaVu-Sans", "-pointsize", "22",
                    "-annotate", "+290+70", text,
                    "-fill", "#9aa0a6", "-pointsize", "18", "-annotate", "+20+40", f"{screen['window']}",
                    png.as_posix()], check=True)
    subprocess.run(["magick", png.as_posix(), "-resize", "1280x1280>", "-quality", "60", jpg.as_posix()], check=True)
    png.unlink()
    print("screen", jpg)


if __name__ == "__main__":
    ASSETS.mkdir(exist_ok=True)
    spec = json.loads((HERE / "cases.json").read_text())
    make_screen(spec)
    make_audio(spec)
