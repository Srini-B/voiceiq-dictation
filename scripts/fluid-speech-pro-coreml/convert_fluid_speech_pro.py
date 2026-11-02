#!/usr/bin/env python3
"""Convert Fluid Speech Pro (FluidVoice-Labs/fluid-speech-pro) to an fp16 Core ML package for FluidAudio `.v3`.

Fluid Speech Pro is Parakeet TDT 0.6B v3 plus one residual block, `encoder.fv_insert`, run as a forward hook on
the output of `encoder.pre_encode`. The model is loaded with the repository's `fluid_speech.load`, which attaches
the block and loads every tensor strictly, so the traced encoder contains it. The wrappers are mobius'
(`models/stt/parakeet-tdt-v3-0.6b/coreml/individual_components.py`); I/O names and shapes follow the
FluidInference v3 Core ML contract (15 s window, single-step joint with top-K 64).

Every component is converted with fp16 weights and fp16 compute (no palettization or integer quantization),
minimum deployment target iOS 18 / macOS 15, then compiled with `xcrun coremlcompiler`.

    uv venv -p 3.11 .venv && VIRTUAL_ENV=.venv uv pip install -r requirements.txt
    .venv/bin/python convert_fluid_speech_pro.py --out <package dir>
"""
from __future__ import annotations

import argparse
import gc
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
import soundfile as sf
import torch

HERE = Path(__file__).resolve().parent
MOBIUS_V3 = HERE / "mobius" / "models" / "stt" / "parakeet-tdt-v3-0.6b" / "coreml"
sys.path.insert(0, str(MOBIUS_V3))
sys.path.insert(0, str(HERE / "hf"))

import coremltools as ct  # noqa: E402

import fluid_speech  # noqa: E402
from individual_components import (  # noqa: E402
    DecoderWrapper,
    EncoderWrapper,
    JointDecisionSingleStep,
    JointWrapper,
    PreprocessorWrapper,
)

REPO = "FluidVoice-Labs/fluid-speech-pro"
REVISION = "53f490b9292c5943847f635b7abfc3f123018964"
NEMO_SHA256 = "d62df3993df8b3b34626baeba3139650a6d149dd4603cbb3b17c51552714b537"
SAMPLE_RATE = 16_000
WINDOW_SAMPLES = 240_000
TOP_K = 64
TRACE_AUDIO = MOBIUS_V3 / "audio" / "yc_first_minute_16k_15s.wav"
AUTHOR = "FluidVoice"
DESCRIPTION_PREFIX = "Fluid Speech Pro by FluidVoice (fp16)"


def fetch_nemo(path: Path) -> Path:
    if not path.exists():
        from huggingface_hub import hf_hub_download

        downloaded = hf_hub_download(REPO, "fluid-speech-pro.nemo", revision=REVISION, local_dir=path.parent)
        path = Path(downloaded)
    digest = subprocess.run(["shasum", "-a", "256", str(path)], check=True, capture_output=True, text=True)
    assert digest.stdout.split()[0] == NEMO_SHA256, f"{path} does not match the {REVISION} LFS digest"
    return path


def load_model(nemo: Path):
    model = fluid_speech.load(str(nemo), map_location="cpu")
    assert hasattr(model.encoder, "fv_insert"), "fluid_speech.load did not attach encoder.fv_insert"
    assert len(model.encoder.pre_encode._forward_hooks) == 1, "expected exactly one hook on encoder.pre_encode"
    model.decoder._rnnt_export = True
    return model


def trace_audio() -> tuple[torch.Tensor, torch.Tensor]:
    data, sr = sf.read(str(TRACE_AUDIO), dtype="float32")
    assert sr == SAMPLE_RATE
    data = np.pad(data, (0, max(0, WINDOW_SAMPLES - data.size)))[:WINDOW_SAMPLES]
    return torch.from_numpy(data)[None], torch.tensor([WINDOW_SAMPLES], dtype=torch.int32)


def without_block(encoder: torch.nn.Module):
    """Context manager that removes the fv_insert hook, for the with/without-block check."""

    class _Ctx:
        def __enter__(self):
            self.hooks = dict(encoder.pre_encode._forward_hooks)
            encoder.pre_encode._forward_hooks.clear()

        def __exit__(self, *exc):
            encoder.pre_encode._forward_hooks.update(self.hooks)

    return _Ctx()


def export(name: str, traced, inputs, outputs, description: str, work: Path, out: Path) -> None:
    mlmodel = ct.convert(
        traced,
        convert_to="mlprogram",
        inputs=inputs,
        outputs=outputs,
        compute_units=ct.ComputeUnit.CPU_ONLY,
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.iOS18,
    )
    mlmodel.short_description = f"{DESCRIPTION_PREFIX}: {description}"
    mlmodel.author = AUTHOR
    mlmodel.license = "CC-BY-4.0"
    mlmodel.user_defined_metadata["fluidspeech.source"] = f"{REPO}@{REVISION}"
    package = work / f"{name}.mlpackage"
    if package.exists():
        shutil.rmtree(package)
    mlmodel.save(str(package))
    print("compiled", compile_into(package, out))


def compile_into(package: Path, out_dir: Path) -> Path:
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(["xcrun", "coremlcompiler", "compile", str(package), tmp], check=True, capture_output=True)
        compiled = Path(tmp) / f"{package.stem}.mlmodelc"
        target = out_dir / compiled.name
        if target.exists():
            shutil.rmtree(target)
        shutil.move(str(compiled), target)
    return target


def write_vocab(model, path: Path) -> None:
    """FluidAudio's format: id -> SentencePiece piece, with the word-boundary mark U+2581 written as a space."""
    sp = model.tokenizer.tokenizer
    vocab = {str(i): sp.id_to_piece(i).replace("\u2581", " ") for i in range(model.tokenizer.vocab_size)}
    path.write_text(json.dumps(vocab, indent=2, ensure_ascii=False))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--nemo", type=Path, default=HERE / "hf" / "fluid-speech-pro.nemo")
    ap.add_argument("--work", type=Path, default=HERE / "build", help="mlpackages and torch reference outputs")
    ap.add_argument("--out", type=Path, required=True, help="package dir (Preprocessor/Encoder/Decoder/JointDecisionv3)")
    args = ap.parse_args()
    args.work.mkdir(parents=True, exist_ok=True)
    args.out.mkdir(parents=True, exist_ok=True)

    model = load_model(fetch_nemo(args.nemo))
    audio, audio_len = trace_audio()

    pre = PreprocessorWrapper(model.preprocessor.eval())
    enc = EncoderWrapper(model.encoder.eval())
    dec = DecoderWrapper(model.decoder.eval())
    joint = JointWrapper(model.joint.eval())
    with torch.no_grad():
        mel, mel_len = pre(audio, audio_len)
        mel, mel_len = mel.clone(), mel_len.to(torch.int32).clone()
        enc_ref, enc_len = enc(mel, mel_len)
        enc_ref = enc_ref.clone()
        with without_block(model.encoder):
            enc_plain, _ = enc(mel, mel_len)
    print("mel", tuple(mel.shape), "encoder", tuple(enc_ref.shape), "encoder_length", enc_len.tolist())

    traced = torch.jit.trace(pre, (audio, audio_len), strict=False).eval()
    export(
        "Preprocessor", traced,
        [ct.TensorType(name="audio_signal", shape=(1, WINDOW_SAMPLES), dtype=np.float32),
         ct.TensorType(name="audio_length", shape=(1,), dtype=np.int32)],
        [ct.TensorType(name="mel", dtype=np.float32), ct.TensorType(name="mel_length", dtype=np.int32)],
        "preprocessor (15 s window)",
        args.work, args.out,
    )

    traced = torch.jit.trace(enc, (mel, mel_len), strict=False).eval()
    with torch.no_grad():
        traced_out, _ = traced(mel, mel_len)
    block_effect = (enc_ref - enc_plain).abs().max().item()
    trace_error = (traced_out - enc_ref).abs().max().item()
    print(f"encoder: max|with - without fv_insert| {block_effect:.4f}, max|traced - eager with block| {trace_error:.2e}")
    assert trace_error < 1e-4 < block_effect, "the traced encoder does not contain encoder.fv_insert"
    export(
        "Encoder", traced,
        [ct.TensorType(name="mel", shape=tuple(mel.shape), dtype=np.float32),
         ct.TensorType(name="mel_length", shape=(1,), dtype=np.int32)],
        [ct.TensorType(name="encoder", dtype=np.float32), ct.TensorType(name="encoder_length", dtype=np.int32)],
        "encoder with fv_insert (15 s window)",
        args.work, args.out,
    )
    del traced, traced_out
    gc.collect()

    layers, hidden = int(model.decoder.pred_rnn_layers), int(model.decoder.pred_hidden)
    targets = torch.full((1, 1), model.decoder.blank_idx, dtype=torch.int32)
    target_len = torch.tensor([1], dtype=torch.int32)
    zero = torch.zeros(layers, 1, hidden)
    traced = torch.jit.trace(dec, (targets, target_len, zero, zero), strict=False).eval()
    export(
        "Decoder", traced,
        [ct.TensorType(name="targets", shape=(1, 1), dtype=np.int32),
         ct.TensorType(name="target_length", shape=(1,), dtype=np.int32),
         ct.TensorType(name="h_in", shape=(layers, 1, hidden), dtype=np.float32),
         ct.TensorType(name="c_in", shape=(layers, 1, hidden), dtype=np.float32)],
        [ct.TensorType(name="decoder", dtype=np.float32), ct.TensorType(name="h_out", dtype=np.float32),
         ct.TensorType(name="c_out", dtype=np.float32)],
        "decoder (RNNT prediction network)",
        args.work, args.out,
    )

    with torch.no_grad():
        dec_step, _, _ = dec(targets, target_len, zero, zero)
    jd = JointDecisionSingleStep(joint, int(model.tokenizer.vocab_size), int(model.joint.num_extra_outputs), TOP_K)
    enc_step = enc_ref[:, :, :1].contiguous()
    traced = torch.jit.trace(jd, (enc_step, dec_step.clone()), strict=False).eval()
    export(
        "JointDecisionv3", traced,
        [ct.TensorType(name="encoder_step", shape=(1, enc_ref.shape[1], 1), dtype=np.float32),
         ct.TensorType(name="decoder_step", shape=(1, hidden, 1), dtype=np.float32)],
        [ct.TensorType(name="token_id", dtype=np.int32), ct.TensorType(name="token_prob", dtype=np.float32),
         ct.TensorType(name="duration", dtype=np.int32), ct.TensorType(name="top_k_ids", dtype=np.int32),
         ct.TensorType(name="top_k_logits", dtype=np.float32)],
        f"single-step joint decision (top-K {TOP_K})",
        args.work, args.out,
    )

    write_vocab(model, args.out / "parakeet_vocab.json")
    print("wrote", args.out / "parakeet_vocab.json")


if __name__ == "__main__":
    main()
