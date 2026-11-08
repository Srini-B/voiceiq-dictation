"""Runs the cleanup cases through a GGUF on llama-server, the way the iPhone app
runs it: the prompt text the app builds (`LocalWriterPrompt` and the chat
template rendered with thinking off), tokenized by llama.cpp with special
tokens parsed, greedy decoding, stopping at the model's end-of-generation
tokens. Also checks that llama.cpp's tokens match the Hugging Face tokenizer's.

Start the server CPU only, e.g.
  llama-server -m writer.gguf -ngl 0 -t 4 -c 2048 --port 8091
usage: python bench_llama.py MODEL_DIR --server http://127.0.0.1:8091 --cases cases.jsonl --out results/NAME.jsonl
MODEL_DIR is the MLX model folder; only its tokenizer is read.
"""
import argparse
import json
import os
import sys
import time
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from common import STUDENT_SYSTEM  # noqa: E402

p = argparse.ArgumentParser()
p.add_argument("model_dir")
p.add_argument("--server", default="http://127.0.0.1:8091")
p.add_argument("--cases", required=True)
p.add_argument("--out", required=True)
p.add_argument("--label", default=None)
args = p.parse_args()


def post(path, body):
    request = urllib.request.Request(args.server + path, data=json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=600) as response:
        return json.loads(response.read())


def prompt(user):
    # The app's string, byte for byte (LlamaWriterSession).
    return (f"<|im_start|>system\n{STUDENT_SYSTEM}<|im_end|>\n<|im_start|>user\n{user}<|im_end|>\n"
            "<|im_start|>assistant\n<think>\n\n</think>\n\n")


from transformers import AutoTokenizer  # noqa: E402

hf = AutoTokenizer.from_pretrained(args.model_dir)
cases = [json.loads(l) for l in open(args.cases)]
meta = dict(model=args.label or args.model_dir, load_s=0, weights_gb=0, prefix_tokens=0, prefix_prefill_s=0,
            prefix_prefill_tps=0, prefix_peak_gb=0, cache_file_mb=0)
token_mismatch = 0
os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
with open(args.out, "w") as f:
    f.write(json.dumps({"meta": meta}) + "\n")
    for c in cases:
        user = "RAW: " + c["raw"]
        text = prompt(user)
        reference = hf.apply_chat_template([{"role": "system", "content": STUDENT_SYSTEM},
                                            {"role": "user", "content": user}],
                                           add_generation_prompt=True, tokenize=False, enable_thinking=False)
        tokens = post("/tokenize", {"content": text, "add_special": False, "parse_special": True})["tokens"]
        if text != reference or tokens != hf.encode(reference, add_special_tokens=True):
            token_mismatch += 1
            print(f"{c['id']}: PROMPT MISMATCH")
        max_tokens = max(160, int(len(c["raw"].split()) * 2.5) + 80)
        t0 = time.time()
        r = post("/completion", {"prompt": tokens, "n_predict": max_tokens, "temperature": 0, "top_k": 1,
                                 "repeat_penalty": 1.0, "cache_prompt": False, "seed": 0})
        total = time.time() - t0
        out = r["content"]
        timings = r.get("timings", {})
        rec = dict(id=c["id"], output=out.strip(), raw_output=out, cached=False, suffix_tokens=len(tokens),
                   gen_tokens=timings.get("predicted_n", 0), finish=r.get("stop_type"),
                   ttft_s=round(timings.get("prompt_ms", 0) / 1000, 3), total_s=round(total, 3),
                   gen_tps=round(timings.get("predicted_per_second", 0), 1), peak_gb=0, cold=None)
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")
        f.flush()
        print(f"{c['id']}: {total:.2f}s prompt {rec['ttft_s']}s {rec['gen_tokens']} tok")
print(json.dumps({"prompt_mismatches": token_mismatch, "cases": len(cases)}))
