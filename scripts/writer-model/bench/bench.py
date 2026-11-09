"""Runs the cleanup cases through one MLX model on Apple silicon.

The static prompt prefix (rules, writing rules, examples, layout reminder) is
prefilled once and saved as a KV cache, the way an on-device integration
would keep it; each case then prefills only "RAW: ...\\nCLEAN:" plus the chat
template's tail. The first case is also run cold (whole prompt, no cache) to
measure the uncached cost and peak memory.

usage: python bench.py MODEL_REPO --prefix prompt_prefix.txt --cases cases.jsonl --out results/NAME.jsonl
       python bench.py MODEL_DIR --system ../system.txt --student --cases rules_cases.jsonl --out results/NAME.jsonl
"""
import argparse
import json
import os
import re
import sys
import tempfile
import time
from pathlib import Path

import mlx.core as mx
from mlx_lm import load, stream_generate
from mlx_lm.models.cache import load_prompt_cache, make_prompt_cache, save_prompt_cache
from mlx_lm.sample_utils import make_sampler

p = argparse.ArgumentParser()
p.add_argument("model")
p.add_argument("--prefix", default=None)
p.add_argument("--cases", required=True)
p.add_argument("--out", required=True)
p.add_argument("--only", default=None, help="comma-separated case ids")
# For fine-tunes trained on their own prompt: an optional system message, the
# user message format ({prefix} and {raw}), and --no-chat for raw completion.
p.add_argument("--system", default=None, help="file holding a system message; stripped, as the app sends system.txt")
p.add_argument("--user-format", default="{prefix}RAW: {raw}\nCLEAN:")
p.add_argument("--no-chat", action="store_true")
p.add_argument("--student", action="store_true",
               help="user message from common.student_user(case), with the case's rules and spelling")
args = p.parse_args()


def peak_reset():
    (getattr(mx, "reset_peak_memory", None) or mx.metal.reset_peak_memory)()


def peak():
    return (getattr(mx, "get_peak_memory", None) or mx.metal.get_peak_memory)() / 1e9


prefix = open(args.prefix).read() if args.prefix else ""
# Stripped as common.STUDENT_SYSTEM is: Qwen3's template keeps a trailing newline.
system = open(args.system).read().strip() if args.system else None
cases = [json.loads(l) for l in open(args.cases)]
if args.only:
    keep = set(args.only.split(","))
    cases = [c for c in cases if c["id"] in keep]

t0 = time.time()
model, tokenizer = load(args.model)
load_s = time.time() - t0
weights_gb = peak()
bos = getattr(tokenizer, "bos_token", None)


if args.student:
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    from common import student_user


def render(case):
    if args.student:
        content = student_user(case)
    else:
        content = args.user_format.replace("{prefix}", prefix).replace("{raw}", case["raw"])
    if args.no_chat:
        return tokenizer.encode(content)
    msgs = ([{"role": "system", "content": system}] if system else []) + [{"role": "user", "content": content}]
    try:
        text = tokenizer.apply_chat_template(msgs, add_generation_prompt=True, tokenize=False, enable_thinking=False)
    except TypeError:
        text = tokenizer.apply_chat_template(msgs, add_generation_prompt=True, tokenize=False)
    add_special = not (bos and text.startswith(bos))
    return tokenizer.encode(text, add_special_tokens=add_special)


a, b = render({"raw": "alpha"}), render({"raw": "omega zeta"})
shared = 0
while shared < min(len(a), len(b)) and a[shared] == b[shared]:
    shared += 1
shared -= 1  # leave the boundary token to the per-case suffix
prefix_tokens = a[:shared]

fd, cache_path = tempfile.mkstemp(prefix=f"wb-cache-{re.sub(r'[^A-Za-z0-9]+', '_', args.model)}-", suffix=".safetensors")
os.close(fd)
peak_reset()
cache = make_prompt_cache(model)
t0 = time.time()
step = 512
for i in range(0, len(prefix_tokens), step):
    model(mx.array(prefix_tokens[i:i + step])[None], cache=cache)
    mx.eval([c.state for c in cache])
prefill_s = time.time() - t0
prefill_peak = peak()
save_prompt_cache(cache_path, cache)
cache_mb = os.path.getsize(cache_path) / 1e6
del cache

sampler = make_sampler(temp=0.0)
os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
meta = dict(model=args.model, load_s=round(load_s, 2), weights_gb=round(weights_gb, 3),
            prefix_tokens=len(prefix_tokens), prefix_prefill_s=round(prefill_s, 2),
            prefix_prefill_tps=round(len(prefix_tokens) / max(prefill_s, 1e-6), 1), prefix_peak_gb=round(prefill_peak, 3),
            cache_file_mb=round(cache_mb, 1))
print(json.dumps(meta))


def run(tokens, prompt_cache, max_tokens):
    out, last = [], None
    t0 = time.time()
    first = None
    for r in stream_generate(model, tokenizer, tokens, max_tokens=max_tokens, sampler=sampler, prompt_cache=prompt_cache):
        if first is None:
            first = time.time() - t0
        out.append(r.text)
        last = r
    total = time.time() - t0
    return "".join(out), last, first, total


def clean(text):
    text = re.sub(r"<think>.*?</think>", "", text, flags=re.S)
    return text.strip()


with open(args.out, "w") as f:
    f.write(json.dumps({"meta": meta}) + "\n")
    for n, c in enumerate(cases):
        tokens = render(c)
        max_tokens = max(160, int(len(c["raw"].split()) * 2.5) + 80)
        cold = None
        if n == 0:
            peak_reset()
            _, r, ttft, total = run(tokens, make_prompt_cache(model), max_tokens)
            cold = dict(prompt_tokens=r.prompt_tokens, ttft_s=round(ttft, 2), total_s=round(total, 2),
                        prompt_tps=round(r.prompt_tps, 1), peak_gb=round(peak(), 3))
        if tokens[:len(prefix_tokens)] == prefix_tokens:
            pc = load_prompt_cache(cache_path)
            suffix = tokens[len(prefix_tokens):]
            cached = True
        else:
            pc, suffix, cached = make_prompt_cache(model), tokens, False
        peak_reset()
        text, r, ttft, total = run(suffix, pc, max_tokens)
        rec = dict(id=c["id"], output=clean(text), raw_output=text, cached=cached,
                   suffix_tokens=len(suffix), gen_tokens=r.generation_tokens, finish=r.finish_reason,
                   ttft_s=round(ttft, 3), total_s=round(total, 3), gen_tps=round(r.generation_tps, 1),
                   peak_gb=round(peak(), 3), cold=cold)
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")
        f.flush()
        print(f"{c['id']}: {total:.2f}s {r.generation_tokens} tok {'cached' if cached else 'UNCACHED'}")
os.remove(cache_path)
