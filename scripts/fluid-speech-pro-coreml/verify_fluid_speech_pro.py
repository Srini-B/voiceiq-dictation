#!/usr/bin/env python3
"""Check a converted Fluid Speech Pro Core ML package against the PyTorch model.

1. Component parity (preprocessor, encoder, decoder, joint) on the same inputs, per compute unit.
2. Proof that the encoder contains `encoder.fv_insert`: Core ML vs torch with the block and torch without it.
3. Transcripts: NeMo `model.transcribe` vs a Core ML pipeline with NeMo's greedy TDT loop on 15 s windows, plus
   the same windowed loop on the PyTorch modules (`torch_window`), which separates conversion error from the
   effect of zero-padding to the fixed 15 s window. Clips longer than 15 s are cut into consecutive windows with
   the decoder state carried over (no overlap, unlike FluidAudio).

    .venv/bin/python verify_fluid_speech_pro.py --package <package dir> --clips <dir of 16 kHz mono wavs> --report <json>
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import time
from pathlib import Path

import coremltools as ct
import numpy as np
import soundfile as sf
import torch

from convert_fluid_speech_pro import (
    TRACE_AUDIO,
    WINDOW_SAMPLES,
    fetch_nemo,
    load_model,
    without_block,
)

HERE = Path(__file__).resolve().parent
UNITS = {"cpu": ct.ComputeUnit.CPU_ONLY, "ane": ct.ComputeUnit.CPU_AND_NE, "gpu": ct.ComputeUnit.CPU_AND_GPU}


def diff(coreml: np.ndarray, ref: np.ndarray) -> dict:
    coreml, ref = np.asarray(coreml, np.float64), np.asarray(ref, np.float64)
    return {
        "max_abs": float(np.abs(coreml - ref).max()),
        "rel_l2": float(np.linalg.norm(coreml - ref) / np.linalg.norm(ref)),
        "ref_max_abs": float(np.abs(ref).max()),
    }


def read_clip(path: Path) -> np.ndarray:
    data, sr = sf.read(str(path), dtype="float32")
    assert sr == 16_000 and data.ndim == 1, f"{path}: expected 16 kHz mono"
    return data


def window(samples: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    padded = np.zeros((1, WINDOW_SAMPLES), np.float32)
    padded[0, : samples.size] = samples[:WINDOW_SAMPLES]
    return padded, np.array([min(samples.size, WINDOW_SAMPLES)], np.int32)


class Torch:
    def __init__(self, model):
        self.m = model

    @torch.no_grad()
    def mel(self, audio, length):
        mel, mel_len = self.m.preprocessor(input_signal=torch.from_numpy(audio), length=torch.from_numpy(length).long())
        return mel.numpy(), mel_len.numpy().astype(np.int32)

    @torch.no_grad()
    def encode(self, mel, mel_len):
        enc, enc_len = self.m.encoder(audio_signal=torch.from_numpy(mel), length=torch.from_numpy(mel_len).long())
        return enc.numpy(), enc_len.numpy().astype(np.int32)

    @torch.no_grad()
    def decode(self, token, h, c):
        out, _, (h2, c2) = self.m.decoder(
            targets=torch.tensor([[token]]), target_length=torch.tensor([1]),
            states=[torch.from_numpy(h), torch.from_numpy(c)],
        )
        return out.numpy(), h2.numpy(), c2.numpy()

    @torch.no_grad()
    def joint_logits(self, enc_step, dec_step):
        j = self.m.joint
        x = j.enc(torch.from_numpy(enc_step).transpose(1, 2)).unsqueeze(2) + j.pred(
            torch.from_numpy(dec_step).transpose(1, 2)).unsqueeze(1)
        return j.joint_net(x).numpy().reshape(-1)

    def decide(self, enc_step, dec_step):
        logits = self.joint_logits(enc_step.astype(np.float32), dec_step.astype(np.float32))
        blank = self.m.decoder.blank_idx
        return {"token_id": np.array([np.argmax(logits[:blank + 1])]), "duration": np.array([np.argmax(logits[blank + 1:])])}


class CoreML:
    def __init__(self, package: Path, encoder_units: str, rest_units: str):
        load = lambda name, units: ct.models.CompiledMLModel(str(package / f"{name}.mlmodelc"), compute_units=UNITS[units])
        self.pre = load("Preprocessor", "cpu")
        self.enc = load("Encoder", encoder_units)
        self.dec = load("Decoder", rest_units)
        self.joint = load("JointDecisionv3", rest_units)

    def mel(self, audio, length):
        out = self.pre.predict({"audio_signal": audio, "audio_length": length})
        return out["mel"], out["mel_length"].astype(np.int32)

    def encode(self, mel, mel_len):
        out = self.enc.predict({"mel": mel.astype(np.float32), "mel_length": mel_len})
        return out["encoder"], out["encoder_length"].astype(np.int32)

    def decode(self, token, h, c):
        out = self.dec.predict({"targets": np.array([[token]], np.int32), "target_length": np.array([1], np.int32),
                                "h_in": h, "c_in": c})
        return out["decoder"], out["h_out"], out["c_out"]

    def decide(self, enc_step, dec_step):
        return self.joint.predict({"encoder_step": enc_step.astype(np.float32), "decoder_step": dec_step.astype(np.float32)})


def greedy_tdt(cm: CoreML, enc: np.ndarray, enc_len: int, state, durations, blank: int, max_symbols: int):
    """NeMo GreedyTDTInfer._greedy_decode with the Core ML decoder and joint (state carried across windows)."""
    h, c, last, dec_out = state
    if dec_out is None:
        dec_out, h, c = cm.decode(blank, h, c)
    tokens = []
    t = 0
    while t < enc_len:
        symbols = 0
        need_loop = True
        while need_loop and symbols < max_symbols:
            out = cm.decide(enc[:, :, t:t + 1], dec_out)
            k = int(out["token_id"].reshape(-1)[0])
            skip = durations[int(out["duration"].reshape(-1)[0])]
            if k != blank:
                tokens.append(k)
                dec_out, h, c = cm.decode(k, h, c)
                last = k
            symbols += 1
            t += skip
            need_loop = skip == 0
        if symbols == max_symbols:
            t += 1
    return tokens, (h, c, last, dec_out)


def parity(model, package: Path, clips: list[Path]) -> dict:
    tm = Torch(model)
    mil = (package / "Encoder.mlmodelc" / "model.mil").read_text()
    report = {"encoder_mil": {
        "fv_insert_consts": sorted(set(re.findall(r"fv_insert_\w+?_to_fp16", mil))),
        "gelu_ops": mil.count("gelu("),  # GELU appears only in fv_insert; the Conformer layers use SiLU
    }}
    sources = {"trace_audio_15s": read_clip(TRACE_AUDIO)}
    if clips:
        sources[clips[0].stem] = read_clip(clips[0])
    for label, samples in sources.items():
        audio, length = window(samples)
        r = report[label] = {}
        mel_t, mel_len_t = tm.mel(audio, length)
        pre = ct.models.CompiledMLModel(str(package / "Preprocessor.mlmodelc"), compute_units=UNITS["cpu"])
        out = pre.predict({"audio_signal": audio, "audio_length": length})
        valid = int(mel_len_t[0])
        r["preprocessor_cpu"] = diff(out["mel"][..., :valid], mel_t[..., :valid]) | {
            "mel_length": [int(out["mel_length"][0]), valid]}

        enc_t, enc_len_t = tm.encode(mel_t, mel_len_t)
        with without_block(model.encoder):
            enc_plain, _ = tm.encode(mel_t, mel_len_t)
        frames = int(enc_len_t[0])
        r["block_effect_torch_with_vs_without"] = diff(enc_plain[..., :frames], enc_t[..., :frames])
        for units in ("cpu", "ane", "gpu"):
            enc = ct.models.CompiledMLModel(str(package / "Encoder.mlmodelc"), compute_units=UNITS[units])
            out = enc.predict({"mel": mel_t, "mel_length": mel_len_t})
            e = out["encoder"][..., :frames]
            r[f"encoder_{units}_vs_torch_with_block"] = diff(e, enc_t[..., :frames]) | {
                "encoder_length": [int(out["encoder_length"][0]), frames]}
            r[f"encoder_{units}_vs_torch_without_block"] = diff(e, enc_plain[..., :frames])

        layers, hidden = model.decoder.pred_rnn_layers, model.decoder.pred_hidden
        rng = np.random.default_rng(0)
        tokens = [model.decoder.blank_idx] + rng.integers(0, model.tokenizer.vocab_size, 31).tolist()
        for units in ("cpu", "ane"):
            cm = CoreML(package, "cpu", units)
            hc_t = hc_c = (np.zeros((layers, 1, hidden), np.float32),) * 2
            dec_errs, h_errs, c_errs = [], [], []
            joint_rows = {"token_id_match": 0, "duration_match": 0, "n": 0, "prob": [], "topk_logits": [], "topk_ids_overlap": []}
            for i, tok in enumerate(tokens):
                d_t, h_t, c_t = tm.decode(tok, *hc_t)
                d_c, h_c, c_c = cm.decode(tok, *hc_c)
                dec_errs.append((d_c, d_t)); h_errs.append((h_c, h_t)); c_errs.append((c_c, c_t))
                hc_t, hc_c = (h_t, c_t), (h_c, c_c)
                for f in range(i % 6, frames, 6):
                    step = enc_t[:, :, f:f + 1]
                    logits = tm.joint_logits(step, d_t)
                    tok_logits, dur_logits = logits[:model.tokenizer.vocab_size + 1], logits[-5:]
                    probs = np.exp(tok_logits - tok_logits.max()); probs /= probs.sum()
                    o = cm.decide(step, d_t)
                    k = int(np.argmax(tok_logits))
                    joint_rows["n"] += 1
                    joint_rows["token_id_match"] += int(o["token_id"].reshape(-1)[0]) == k
                    joint_rows["duration_match"] += int(o["duration"].reshape(-1)[0]) == int(np.argmax(dur_logits))
                    joint_rows["prob"].append((float(o["token_prob"].reshape(-1)[0]), float(probs[k])))
                    ref_ids = np.argsort(-tok_logits)[:64]
                    joint_rows["topk_logits"].append((o["top_k_logits"].reshape(-1), tok_logits[ref_ids]))
                    joint_rows["topk_ids_overlap"].append(len(set(o["top_k_ids"].reshape(-1).tolist()) & set(ref_ids.tolist())) / 64)
            stack = lambda pairs: (np.concatenate([p[0].reshape(-1) for p in pairs]), np.concatenate([p[1].reshape(-1) for p in pairs]))
            r[f"decoder_{units}"] = {"steps": len(tokens), "decoder": diff(*stack(dec_errs)), "h_out": diff(*stack(h_errs)),
                                     "c_out": diff(*stack(c_errs))}
            n = joint_rows["n"]
            r[f"joint_{units}"] = {
                "evaluations": n,
                "token_id_agreement": joint_rows["token_id_match"] / n,
                "duration_agreement": joint_rows["duration_match"] / n,
                "token_prob": diff(*np.array(joint_rows["prob"]).T),
                "top_k_logits": diff(*stack(joint_rows["topk_logits"])),
                "top_k_ids_mean_overlap": float(np.mean(joint_rows["topk_ids_overlap"])),
            }
    return report


def transcripts(model, package: Path, clips: list[Path]) -> dict:
    sp = model.tokenizer
    durations = list(model.cfg.decoding.durations)
    blank, max_symbols = model.decoder.blank_idx, int(model.cfg.decoding.greedy.max_symbols)
    layers, hidden = model.decoder.pred_rnn_layers, model.decoder.pred_hidden
    backends = {"coreml_python": CoreML(package, "cpu", "ane"), "torch_window": Torch(model)}

    def windowed(backend, samples):
        state = (np.zeros((layers, 1, hidden), np.float32), np.zeros((layers, 1, hidden), np.float32), None, None)
        ids = []
        for start in range(0, samples.size, WINDOW_SAMPLES):
            audio, length = window(samples[start:start + WINDOW_SAMPLES])
            enc, enc_len = backend.encode(*backend.mel(audio, length))
            new, state = greedy_tdt(backend, enc, int(enc_len[0]), state, durations, blank, max_symbols)
            ids += new
        return sp.ids_to_text(ids)

    def nemo_text(clip):
        hypothesis = model.transcribe([str(clip)], batch_size=1, verbose=False)[0]
        # transcribe() ends with encoder.unfreeze(), which puts the encoder back in training mode; a later
        # direct forward would then update the BatchNorm running statistics and corrupt every result after it.
        model.eval()
        return hypothesis.text

    rows = {}
    for clip in clips:
        samples = read_clip(clip)
        t0 = time.perf_counter()
        nemo = nemo_text(clip)
        nemo_s = time.perf_counter() - t0
        with without_block(model.encoder):
            nemo_plain = nemo_text(clip)
        t0 = time.perf_counter()
        coreml_text = windowed(backends["coreml_python"], samples)
        coreml_s = time.perf_counter() - t0
        rows[clip.stem] = {
            "seconds": round(samples.size / 16_000, 2),
            "nemo": nemo,
            "nemo_without_fv_insert": nemo_plain,
            "coreml_python": coreml_text,
            "torch_window": windowed(backends["torch_window"], samples),
            "coreml_windows": -(-samples.size // WINDOW_SAMPLES),
            "nemo_s": round(nemo_s, 2),
            "coreml_s": round(coreml_s, 2),
        }
        row = rows[clip.stem]
        row["coreml_matches_nemo"] = row["coreml_python"] == row["nemo"]
        row["coreml_matches_torch_window"] = row["coreml_python"] == row["torch_window"]
        print(json.dumps({clip.stem: rows[clip.stem]}, ensure_ascii=False, indent=1), flush=True)
    return rows


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--package", type=Path, required=True)
    ap.add_argument("--clips", type=Path, required=True)
    ap.add_argument("--report", type=Path, required=True)
    ap.add_argument("--nemo", type=Path, default=HERE / "hf" / "fluid-speech-pro.nemo")
    args = ap.parse_args()
    clips = sorted(args.clips.glob("*.wav"))
    model = load_model(fetch_nemo(args.nemo))
    report = {"parity": parity(model, args.package, clips)}
    print(json.dumps(report["parity"], indent=1), flush=True)
    report["transcripts"] = transcripts(model, args.package, clips)
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=1))
    print("wrote", args.report)


if __name__ == "__main__":
    sys.exit(main())
