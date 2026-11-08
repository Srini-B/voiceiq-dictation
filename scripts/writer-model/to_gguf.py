"""Converts a VoiceIQ Writer MLX 4-bit model to a GGUF for llama.cpp.

1. Dequantizes the MLX affine 4-bit weights (group size 64) to float32, which
   is exact, and undoes mlx-lm's Qwen3.5 `sanitize` (conv1d axis order and the
   +1 on the RMSNorm weights), giving a Hugging Face checkpoint.
2. Converts that with llama.cpp's `convert_hf_to_gguf.py` to a float32 GGUF.
3. Quantizes it to Q4_1 with `llama-quantize`, then rewrites every Q4_1 block
   from the MLX grid: each 64-group splits into two 32-blocks that share its
   scale and offset, so the 4-bit codes carry over and only the scale and
   offset round from bfloat16 to float16. A tensor whose values do not sit on
   such a grid keeps llama-quantize's blocks; the summary counts both.

usage: python to_gguf.py MLX_DIR OUT.gguf --llama-cpp /path/to/llama.cpp [--keep-f32]
"""
import argparse
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import mlx.core as mx
import numpy as np

p = argparse.ArgumentParser()
p.add_argument("mlx_dir", type=Path)
p.add_argument("out", type=Path)
p.add_argument("--llama-cpp", type=Path, required=True)
p.add_argument("--quantize-bin", type=Path, default=None)
p.add_argument("--keep-f32", action="store_true")
args = p.parse_args()

llama = args.llama_cpp.resolve()
quantize_bin = args.quantize_bin or llama / "build-cpu/bin/llama-quantize"
sys.path.insert(0, str(llama / "gguf-py"))
import gguf  # noqa: E402

NORM_KEYS = (".input_layernorm.weight", ".post_attention_layernorm.weight", "model.norm.weight",
             ".q_norm.weight", ".k_norm.weight")


def to_hf(mlx_dir: Path, hf_dir: Path):
    config = json.loads((mlx_dir / "config.json").read_text())
    qwen35 = config.get("model_type") == "qwen3_5"
    group, bits = config["quantization"]["group_size"], config["quantization"]["bits"]
    weights = {}
    for path in sorted(mlx_dir.glob("model*.safetensors")):
        weights.update(mx.load(str(path)))
    out = {}
    for key, value in weights.items():
        if key.endswith((".scales", ".biases")):
            continue
        base = key.removesuffix(".weight")
        if f"{base}.scales" in weights:
            value = mx.dequantize(value, weights[f"{base}.scales"].astype(mx.float32),
                                  weights[f"{base}.biases"].astype(mx.float32), group_size=group, bits=bits)
        value = value.astype(mx.float32)
        if qwen35:
            if "conv1d.weight" in key:
                value = value.moveaxis(1, 2)
            elif value.ndim == 1 and key.endswith(NORM_KEYS):
                value = value - 1.0
            key = key.replace("language_model.model.", "model.language_model.", 1)
        out[key] = value
    mx.save_safetensors(str(hf_dir / "model.safetensors"), out, metadata={"format": "pt"})
    for name in ("quantization", "quantization_config"):
        config.pop(name, None)
    (hf_dir / "config.json").write_text(json.dumps(config, indent=2))
    for name in ("tokenizer.json", "tokenizer_config.json", "chat_template.jinja", "generation_config.json"):
        if (mlx_dir / name).exists():
            shutil.copy(mlx_dir / name, hf_dir / name)
    return group


# Groups per batch: the 2B's embedding (508M values) as one batch held more
# than 18 GB of float64 temporaries.
GROUPS_PER_BATCH = 1 << 18


def grid_blocks(values: np.ndarray):
    """Q4_1 blocks for float32 rows that lie on a 64-group affine 4-bit grid,
    or None when a group does not. Groups are independent, so batching does
    not change the result."""
    groups = values.reshape(-1, 64)
    batches = []
    for start in range(0, len(groups), GROUPS_PER_BATCH):
        blocks = grid_batch(groups[start:start + GROUPS_PER_BATCH])
        if blocks is None:
            return None
        batches.append(blocks)
    return np.concatenate(batches)


def grid_batch(groups: np.ndarray):
    """The smallest gap between a group's distinct values is its step, and
    every value must be a whole number of steps, at most 15, above the
    group's minimum."""
    groups = groups.astype(np.float64)
    low = groups.min(axis=1, keepdims=True)
    ordered = np.sort(groups, axis=1)
    gaps = np.diff(ordered, axis=1)
    gaps[gaps <= 1e-12 * np.maximum(1, np.abs(ordered[:, 1:]))] = np.inf
    step = gaps.min(axis=1, keepdims=True)
    step[~np.isfinite(step)] = 1.0  # a constant group: every code is 0
    # When a group skips levels the smallest gap can be several steps
    # ({0, 2, 5} has gap 2): try the gap split into 1, 2, ... steps.
    pending = np.ones(len(groups), dtype=bool)
    final = np.empty_like(step)
    for parts in range(1, 16):
        trial = step[pending] / parts
        c = (groups[pending] - low[pending]) / trial
        ok = (np.abs(c - np.rint(c)).max(axis=1) <= 1e-3) & (np.rint(c).max(axis=1) <= 15)
        index = np.flatnonzero(pending)
        final[index[ok]] = trial[ok]
        pending[index[ok]] = False
        if not pending.any():
            break
    if pending.any():
        return None
    step = final
    rounded = np.rint((groups - low) / step)
    rounded = rounded.astype(np.uint8).reshape(-1, 32)
    d = np.repeat(step, 2, axis=0).astype(np.float16)
    m = np.repeat(low, 2, axis=0).astype(np.float16)
    qs = rounded[:, :16] | (rounded[:, 16:] << 4)
    blocks = np.concatenate([d.view(np.uint8), m.view(np.uint8), qs], axis=1)
    return blocks


def repack(f32_path: Path, q41_path: Path):
    source = {t.name: t for t in gguf.GGUFReader(f32_path).tensors}
    target = gguf.GGUFReader(q41_path, "r+")
    exact = kept = 0
    worst = 0.0
    for tensor in target.tensors:
        if tensor.tensor_type != gguf.GGMLQuantizationType.Q4_1:
            continue
        values = np.asarray(source[tensor.name].data, dtype=np.float32).reshape(-1)
        blocks = grid_blocks(values)
        if blocks is None:
            kept += 1
            print(f"kept llama-quantize blocks: {tensor.name}")
            continue
        data = tensor.data.reshape(-1)
        data[:] = blocks.reshape(-1)
        restored = gguf.quants.dequantize(blocks, gguf.GGMLQuantizationType.Q4_1).reshape(-1)
        worst = max(worst, float(np.abs(restored - values).max()))
        exact += 1
    print(json.dumps({"grid_repacked": exact, "kept": kept, "max_abs_error": worst}))


with tempfile.TemporaryDirectory() as tmp:
    hf = Path(tmp) / "hf"
    hf.mkdir()
    to_hf(args.mlx_dir, hf)
    f32 = Path(tmp) / "model-f32.gguf"
    subprocess.run([sys.executable, str(llama / "convert_hf_to_gguf.py"), str(hf), "--outtype", "f32",
                    "--outfile", str(f32)], check=True)
    # The tied embedding is 4-bit in MLX too; without this llama-quantize makes it Q6_K.
    subprocess.run([str(quantize_bin), "--token-embedding-type", "q4_1", "--output-tensor-type", "q4_1", str(f32), str(args.out), "Q4_1"],
                   check=True)
    repack(f32, args.out)
    if args.keep_f32:
        shutil.copy(f32, args.out.with_suffix(".f32.gguf"))
