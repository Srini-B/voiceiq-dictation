#!/usr/bin/env python3
"""How much of a dictation call's time is the prompt: the same short dictation
(Parakeet transcript of name_01) written under the full prompt and under cut
versions, calls interleaved, one at a time.

python3 prompt_size_probe.py <repo root> <calls per variant>
"""
import json
import statistics
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import bench as b  # noqa: E402

root, n = sys.argv[1], int(sys.argv[2])
manifest = json.loads((b.EVAL_DIR / "manifest.json").read_text())
raw = json.loads((b.HERE / "parakeet_transcripts.json").read_text())["none"]["name_01"]
full = b.prompt_builder(root)(manifest["dictionary"], raw)
examples = b.swift_string((Path(root) / "VoiceIQCore/Sources/FormattingPipeline/PromptV1.swift").read_text(), "examples")
assert "\n\n" + examples + "\n\n" in full
head, tail = full.split("Examples:", 1)
tail = tail[tail.index("THE DICTATION:"):]
variants = {
    "full": full,
    "no examples": full.replace("\n\n" + examples, "", 1),  # keeps layoutReminder, which follows the examples
    "rules cut to 2k chars": head[:2000] + "\n\n" + tail,
}
times = {k: [] for k in variants}
for _ in range(n):
    for name, prompt in variants.items():
        r = b.call(prompt, None)
        if r["ok"]:
            times[name].append((r["dt"], r["prompt_tokens"], r["thought_tokens"]))
for name, rows in times.items():
    dts = sorted(t for t, _, _ in rows)
    print(f"{name:24s} {rows[0][1]:6d} prompt tokens  median {statistics.median(dts):.2f}s  "
          f"min {dts[0]:.2f}s  max {dts[-1]:.2f}s  thinking in {sum(th > 0 for _, _, th in rows)}/{len(rows)}")
