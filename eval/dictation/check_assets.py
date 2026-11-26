#!/usr/bin/env python3
"""Checks that each TTS clip actually says its case's text, before any
score depends on it. The TTS voice sometimes leaves words out (it dropped
"Thanks, Srini." from long_01), and a model can't be faulted for words
the audio never had.

Transcribes every clip with OpenAI gpt-4o-transcribe (not the model under
test) and lists clips whose transcript misses words of the script: any
WER over 25% (the
checking transcriber's own errors stay under that), or a script ending that the transcript doesn't end with.
Native-language and all-filler clips are skipped. Needs OPENAI_API_KEY.
"""
import json
import os
import subprocess
from pathlib import Path

from score import wer, words

HERE = Path(__file__).parent
ASSETS = HERE / ".assets"


def transcribe(path: Path) -> str:
    out = subprocess.run(["curl", "-s", "https://api.openai.com/v1/audio/transcriptions",
                          "-H", f"Authorization: Bearer {os.environ['OPENAI_API_KEY']}",
                          "-F", "model=gpt-4o-transcribe", "-F", f"file=@{path}"],
                         capture_output=True, check=True)
    return json.loads(out.stdout)["text"]


def main() -> None:
    spec = json.loads((HERE / "cases.json").read_text())
    bad = 0
    for case in spec["cases"]:
        if case["voice"] == "native" or case.get("expect") == "<<EMPTY>>" or case.get("audio_check", "").startswith("skip"):
            continue
        heard = transcribe(ASSETS / f"{case['id']}.flac")
        error = wer(case["text"], heard)
        tail_ok = words(heard)[-2:] == words(case["text"])[-2:]
        if error > 0.25 or not tail_ok:
            bad += 1
            print(f"{case['id']}: WER {error:.2f}{'' if tail_ok else ', ending missing'}\n  script: {case['text']}\n  heard:  {heard}")
    print("all clips say their text" if not bad else f"{bad} clips differ from their script; fix the script or regenerate the clip")
    raise SystemExit(1 if bad else 0)


if __name__ == "__main__":
    main()
