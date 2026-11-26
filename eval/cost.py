#!/usr/bin/env python3
"""C1: VoiceiQ's Gemini cost per month, from the tokens an eval run used.

    python3 eval/cost.py eval/dictation/results/LABEL.json [--prices YYYY-MM]

Per dictation: each call's input (audio, and prompt text at the cache hit
share measured in use) and output (answer plus thinking) at the prices in eval/cost.json. A
call that also sent the backup request pays for one more whole call: both
requests run until one answers, and the app cancels the other, which Gemini
may still bill in full. Per meeting hour: the
figure in cost.json until the meeting pipeline records its own usage.

Monthly = per dictation x dictations + per meeting hour x meeting hours. The
score of record uses cost.json's score_profile at its score_prices (the
highest announced prices); every profile is reported. C1 is 100 at or under
target_inr, 90 at ceiling_inr, and loses a point per 1% over the ceiling.

>>> c1(150, 200, 250), c1(200, 200, 250), c1(225, 200, 250), c1(250, 200, 250), c1(275, 200, 250)
(100.0, 100.0, 95.0, 90.0, 80.0)
"""
import argparse
import json
import statistics
from pathlib import Path

HERE = Path(__file__).parent


def c1(monthly: float, target: float, ceiling: float) -> float:
    if monthly <= target:
        return 100.0
    if monthly <= ceiling:
        return round(100 - 10 * (monthly - target) / (ceiling - target), 1)
    return round(max(0.0, 90 - 100 * (monthly - ceiling) / ceiling), 1)


def call_cost(usage: dict, price: dict, cache_share: float) -> float:
    """USD for one dictation as the app sends it, from Gemini's usageMetadata.

    Eval calls run back to back, so they hit Gemini's implicit cache more
    often than dictations spread over a day; the text part of the prompt is
    priced at the hit share measured in use (cost.json), not the eval's."""
    by_modality = {d["modality"]: d["tokenCount"] for d in usage.get("promptTokensDetails", [])}
    audio = by_modality.get("AUDIO", 0)
    prompt_text = usage.get("promptTokenCount", 0) - audio
    cached = prompt_text * cache_share
    text = prompt_text - cached
    out = usage.get("candidatesTokenCount", 0) + usage.get("thoughtsTokenCount", 0)
    m = 1e-6
    one_input = audio * price["audio_in"] * m + text * price["text_in"] * m + cached * price["cached_in"] * m
    one = one_input + out * price["out"] * m
    return one + usage.get("secondRequests", 0) * one


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("run", help="eval/dictation/results/<label>.json")
    ap.add_argument("--prices", help="price period in cost.json; default its score_prices")
    args = ap.parse_args()
    cfg = json.loads((HERE / "cost.json").read_text())
    run = json.loads(Path(args.run).read_text())
    period = args.prices or cfg["score_prices"]
    price = cfg["prices_usd_per_mtok"][period][run["model"]]
    share = cfg["cache_hit_share_in_use"]
    per_dictation = statistics.mean(call_cost(r["usage"], price, share) for r in run["results"]) * cfg["inr_per_usd"]
    per_hour = cfg["meeting_inr_per_hour"][period]
    months = {}
    for name, p in cfg["profiles"].items():
        dictation = per_dictation * p["dictations_per_month"]
        meetings = per_hour * p["meeting_hours_per_month"]
        months[name] = {"dictation": round(dictation), "meetings": round(meetings), "total": round(dictation + meetings),
                        "C1": c1(dictation + meetings, cfg["target_inr"], cfg["ceiling_inr"])}
    print(json.dumps({
        "label": run["label"], "prices": period, "inr_per_dictation": round(per_dictation, 3),
        "cache_share_priced": share, "eval_cached_share": round(sum(r["usage"].get("cachedContentTokenCount", 0) for r in run["results"])
                              / max(1, sum(r["usage"].get("promptTokenCount", 0) for r in run["results"])), 3),
        "backup_requests": sum(r["usage"].get("secondRequests", 0) for r in run["results"]),
        "calls": len(run["results"]), "inr_meeting_hour": per_hour, "months": months,
        "C1": months[cfg["score_profile"]]["C1"],
    }, indent=1))


if __name__ == "__main__":
    main()
