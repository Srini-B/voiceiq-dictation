#!/usr/bin/env python3
"""How often the writer repeats text already before the cursor (echo_cases.json).

Each case is a dictation into a field whose text before the cursor ends with
something the speaker did not say ("[7] ", "3. ", "Hi Priya, ", the end of
the last sentence). The app's own prompt (eval/promptdump, with the field and
screen text as the app reads them) goes to the LLM Gateway, and the answer
gets the app's post-processing. A result echoes when it starts with that
text, or with a line marker ("[7]", "3.", "-", "10:42"), and the transcript
does not.

Usage: echo.py LABEL [--rounds 3] [--model gpt-6-luna]
Writes results/LABEL.echo.json. Needs ASSEMBLYAI_API_KEY.
"""
import argparse
import concurrent.futures
import json
import re
import subprocess
from pathlib import Path

from writer import call

HERE = Path(__file__).parent
MARKER = re.compile(r"^(\[?\d+\]|\d+[.)]|[-•*]|\d{1,2}:\d{2})\s")


def norm(text: str) -> str:
    return " ".join(re.sub(r"[^\w\s]", " ", text.lower()).split())


def echoed(case: dict, written: str) -> bool:
    lines = [line for line in case["before"].split("\n") if line.strip()]
    if not lines:
        return False
    line = lines[-1]
    candidates = [line] + [s for s in re.split(r"(?<=[.!?])\s+", line) if s.strip()][-1:]
    out, heard = norm(written), norm(case["transcript"])
    for text in candidates:
        if norm(text) and out.startswith(norm(text)) and not heard.startswith(norm(text)):
            return True
    return bool(MARKER.match(written.lstrip())) and not MARKER.match(case["transcript"].lstrip())


def run(case: dict, model: str, promptdump: str) -> dict:
    request = {"app": case["app"], "window": case["window"], "before": case["before"],
               "screenText": ["\n".join([case["window"]] + case["lines"])], "transcript": case["transcript"]}
    prompt = subprocess.run([promptdump], input=json.dumps(request).encode(), capture_output=True, check=True).stdout.decode()
    raw, seconds, usage = call(prompt, model, "none" if model.startswith("gpt-6") else None, "gateway")
    post = {"output": raw, "before": case["before"], "transcript": case["transcript"]}
    written = subprocess.run([promptdump], input=json.dumps(post).encode(), capture_output=True, check=True).stdout.decode()
    return {"id": case["id"], "raw": raw, "written": written, "echo_raw": echoed(case, raw),
            "echo": echoed(case, written), "usd": usage["writer_usd"]}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("label")
    ap.add_argument("--rounds", type=int, default=3)
    ap.add_argument("--model", default="gpt-6-luna")
    ap.add_argument("--promptdump", default=str(HERE.parent / "promptdump" / "promptdump"))
    args = ap.parse_args()
    cases = json.loads((HERE / "echo_cases.json").read_text())["cases"]
    with concurrent.futures.ThreadPoolExecutor(2) as pool:
        jobs = [(r, pool.submit(run, c, args.model, args.promptdump)) for r in range(args.rounds) for c in cases]
        results = [dict(job.result(), round=r + 1) for r, job in jobs]
    for r in results:
        if r["echo_raw"] or r["echo"]:
            print(f"r{r['round']} {r['id']}: raw echo={r['echo_raw']} after guard={r['echo']}: {r['written'][:70]!r}")
    n = len(results)
    raw_rate, rate = sum(r["echo_raw"] for r in results), sum(r["echo"] for r in results)
    print(f"{args.label}: echo {raw_rate}/{n} from the writer, {rate}/{n} inserted; ${sum(r['usd'] for r in results):.4f}")
    (HERE / "results" / f"{args.label}.echo.json").write_text(json.dumps(results, indent=1, ensure_ascii=False))


if __name__ == "__main__":
    main()
