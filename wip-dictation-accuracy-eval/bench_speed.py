#!/usr/bin/env python3
"""Interleaved A/B/C/D/E benchmark for Gemini latency, thinking tokens, and implicit caching."""
import base64, json, os, statistics, sys, time, urllib.request
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))
import bench_gemini as bg

MANIFEST = json.loads(Path(".amp/in/orb-backup/eval/manifest.json").read_text())
VOCAB = MANIFEST["dictionary"]
CLIPS = {c["id"]: c for c in MANIFEST["clips"]}

# Test 3 clips: short (name_08, 7s), medium (long_02, 24.5s), long (long_01, 52s)
TEST_IDS = ["name_08", "long_02", "long_01"]

prompt_full = bg.build_prompt_current(VOCAB, include_default_rules=True, include_layout_reminder=True)
prompt_dedup = bg.build_prompt_current(VOCAB, include_default_rules=False, include_layout_reminder=True)
prompt_dedup_norem = bg.build_prompt_current(VOCAB, include_default_rules=False, include_layout_reminder=False)

VARIANTS = [
    ("A_full_low",       prompt_full,        {"thinkingLevel": "low"}, False),
    ("B_dedup_low",      prompt_dedup,       {"thinkingLevel": "low"}, False),
    ("C_dedup_norem",    prompt_dedup_norem, {"thinkingLevel": "low"}, False),
    ("D_full_budget0",   prompt_full,        {"thinkingBudget": 0},    False),
    ("E_dedup_budget0",  prompt_dedup,       {"thinkingBudget": 0},    False),
    ("F_dedup_sysinst",  prompt_dedup,       {"thinkingLevel": "low"}, True),
]

print(f"Prompt chars: full={len(prompt_full)}, dedup={len(prompt_dedup)}, dedup_norem={len(prompt_dedup_norem)}")
results = {name: [] for name, _, _, _ in VARIANTS}

REPS = 5
for rep in range(REPS):
    print(f"\n--- Round {rep+1}/{REPS} ---")
    for cid in TEST_IDS:
        clip = CLIPS[cid]
        for name, prompt, tcfg, sysinst in VARIANTS:
            r = bg.call_gemini(prompt, clip["flac"], tcfg, use_system_instruction=sysinst)
            s = bg.score_clip(clip, r.get("text", "")) if r["ok"] else {"eval_ok": False, "missed_targets": ["ERR"]}
            rec = {"rep": rep, "id": cid, **r, "missed": s["missed_targets"], "keep_miss": s.get("must_keep_miss", [])}
            results[name].append(rec)
            print(f"  {cid:8s} {name:16s} {r['dt']:5.2f}s th={r.get('thought_tokens',0):4d} pt={r.get('prompt_tokens',0):5d} cache={r.get('cached_tokens',0):5d} out={r.get('out_tokens',0):3d} miss={rec['missed']} keep_miss={rec['keep_miss']}", flush=True)

print("\n=== SUMMARY BY VARIANT (all 3 clips x 5 rounds = 15 calls) ===")
for name, _, _, _ in VARIANTS:
    rs = results[name]
    ok = [r for r in rs if r["ok"]]
    dts = [r["dt"] for r in ok]
    ths = [r["thought_tokens"] for r in ok]
    long_dts = [r["dt"] for r in ok if r["id"] == "long_01"]
    long_ths = [r["thought_tokens"] for r in ok if r["id"] == "long_01"]
    caches = [r["cached_tokens"] for r in ok]
    print(
        f"{name:16s} | err={len(rs)-len(ok)} | all med={statistics.median(dts):5.2f}s (range {min(dts):.2f}-{max(dts):.2f}s) "
        f"| long52s med={statistics.median(long_dts):5.2f}s (range {min(long_dts):.2f}-{max(long_dts):.2f}s) "
        f"| th>0: {sum(1 for x in ths if x>0):2d}/{len(ths)} (long th={long_ths}) | max_cache={max(caches)}"
    )

Path(".amp/in/orb-backup/eval/speed_ablation.json").write_text(json.dumps(results, indent=2))
