#!/usr/bin/env python3
"""D5 and C1 from the owner's real use, at no cost: reads the app's own
History (history.sqlite: each dictation's key-up-to-text time) and usage
ledger (usage.sqlite: every model call's tokens) on the Mac, read-only, and
makes no network call.

    python3 eval/realuse.py [--days 14] [--prices 2027-01] [--dir PATH]

--dir defaults to ~/Library/Application Support/VoiceiQ. Run it on the Mac
that dictates (it covers that Mac's dictations and calls; iPhone rows that
reached it through iCloud are left out, since their calls are metered on the
iPhone).

D5 is the eval's formula (pool_latency.d5) over pipelineSeconds, which the
app measures from key-up to the text inserted, so no overhead is added.
C1 is cost.py's formula with this window's own figures: dictations and
meeting hours a month, cost per dictation at cost.json's prices, and the
prompt-cache share actually hit. Models cost.json has no price for (meeting
transcription, on device) use the cost the app booked at today's prices.
"""
import argparse
import json
import sqlite3
import statistics
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

from cost import c1

sys.path.insert(0, str(Path(__file__).parent / "dictation"))
from score import percentile  # noqa: E402

HERE = Path(__file__).parent
DONE = ("inserted", "copiedToClipboard", "awaitingChip")
AUDIO_TOKENS_PER_SECOND = 32  # TokenUsage.audioTokensPerSecond


def d5(times: list[float]) -> dict:
    # The formula in score.py and pool_latency.py.
    p50, p90 = statistics.median(times), percentile(times, 0.9)
    score = max(0.0, 100 - 15 * max(0, p50 - 3.0) - 10 * max(0, p90 - 3.5))
    return {"calls": len(times), "e2e_p50": round(p50, 2), "e2e_p90": round(p90, 2), "D5": round(score, 1)}


def open_ro(path: Path) -> sqlite3.Connection:
    # mode=ro: never writes, so it is safe beside the running app.
    db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    db.row_factory = sqlite3.Row
    return db


def priced(row: sqlite3.Row, prices: dict) -> float | None:
    """USD for one call at cost.json's prices; None when the model has none."""
    p = prices.get(row["model"])
    if p is None:
        return None
    m = 1e-6
    return (row["audioIn"] * p["audio_in"] + (row["textIn"] + row["imageIn"]) * p["text_in"]
            + row["cachedIn"] * p["cached_in"] + (row["textOut"] + row["audioOut"] + row["thoughtOut"]) * p["out"]) * m


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=float, default=14)
    ap.add_argument("--prices", help="price period in cost.json; default its score_prices")
    ap.add_argument("--dir", type=Path, default=Path.home() / "Library/Application Support/VoiceiQ")
    args = ap.parse_args()
    cfg = json.loads((HERE / "cost.json").read_text())
    period = args.prices or cfg["score_prices"]
    prices = cfg["prices_usd_per_mtok"][period]
    since = (datetime.now(timezone.utc) - timedelta(days=args.days)).strftime("%Y-%m-%d %H:%M:%S")
    per_month = 30 / args.days

    history = open_ro(args.dir / "history.sqlite")
    rows = history.execute(
        "SELECT id, status, pipelineSeconds, steps FROM dictation WHERE startedAt >= ? AND origin IS NULL",
        (since,)).fetchall()
    done = [r for r in rows if r["status"] in DONE and r["pipelineSeconds"] is not None]
    times = [r["pipelineSeconds"] for r in done]
    steps = {}
    for r in done:
        for k, v in json.loads(r["steps"] or "{}").items():
            if v is not None:
                steps.setdefault(k, []).append(v)
    latency = d5(times) if len(times) >= 10 else {"calls": len(times), "D5": None, "note": "fewer than 10 dictations"}
    latency["step_p50"] = {k: round(statistics.median(v), 2) for k, v in steps.items()}
    latency["failed"] = sum(r["status"] == "failed" for r in rows)

    usage = open_ro(args.dir / "usage.sqlite")
    calls = usage.execute("SELECT * FROM usage WHERE at >= ?", (since,)).fetchall()
    inr = cfg["inr_per_usd"]

    def cost(rows):
        usd, booked = 0.0, 0
        for r in rows:
            p = priced(r, prices)
            if p is None:
                p, booked = r["costUSD"] or 0.0, booked + 1
            usd += p
        return usd * inr, booked

    dict_calls = [r for r in calls if r["activity"] == "dictation"]
    dict_inr, dict_booked = cost(dict_calls)
    n = len(done)
    text = sum(r["textIn"] + r["cachedIn"] for r in dict_calls)
    sessions = {r["sessionID"] for r in dict_calls if r["sessionID"]}
    gemini_dict = [r for r in dict_calls if r["model"].startswith("gemini")]
    meet_calls = [r for r in calls if r["activity"] == "meeting"]
    meet_inr, meet_booked = cost(meet_calls)
    meet_hours = sum(r["audioSeconds"] or r["audioIn"] / AUDIO_TOKENS_PER_SECOND
                     for r in meet_calls if r["stage"] in ("meetingTranscribe", "liveTranscribe")) / 3600

    month_dict = dict_inr * per_month
    month_meet = meet_inr * per_month
    print(json.dumps({
        "window_days": args.days, "prices": period,
        "dictation": {
            "dictations": n, "per_month": round(n * per_month), "gemini_calls": len(gemini_dict),
            "calls_per_dictation": round(len(gemini_dict) / max(1, len(sessions)), 3),
            "inr_per_dictation": round(dict_inr / max(1, n), 3),
            "cache_hit_share": round(sum(r["cachedIn"] for r in dict_calls) / max(1, text), 3),
            "thinking_tokens_per_call": round(statistics.mean([r["thoughtOut"] for r in gemini_dict]), 1) if gemini_dict else None,
            "calls_at_booked_cost": dict_booked,
            **latency,
        },
        "meetings": {"hours": round(meet_hours, 2), "per_month_hours": round(meet_hours * per_month, 1),
                     "inr_per_hour": round(meet_inr / meet_hours, 1) if meet_hours else None,
                     "calls_at_booked_cost": meet_booked},
        "month_inr": {"dictation": round(month_dict), "meetings": round(month_meet), "total": round(month_dict + month_meet)},
        "C1": c1(month_dict + month_meet, cfg["target_inr"], cfg["ceiling_inr"]),
    }, indent=1))


if __name__ == "__main__":
    main()
