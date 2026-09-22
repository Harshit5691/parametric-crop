#!/usr/bin/env python3
"""Produce a premium quote and burn analysis for the demo policy.

    python quote.py --sum-insured 2000000 --start 1995 --end 2024

Writes a JSON artefact to out/quote.json for the contracts and dashboards to
consume, and prints the panel used in the demo.
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "src"))

from parametric.burn import Loading, run_burn, calibrate_thresholds  # noqa: E402
from parametric.policy import USDC_DECIMALS  # noqa: E402
from parametric.rainfall import fetch_daily_rainfall  # noqa: E402
from parametric.regions import PHASE_WINDOWS, YAVATMAL, build_policy  # noqa: E402

OUT_DIR = Path(__file__).resolve().parent / "out"


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument(
        "--sum-insured",
        type=float,
        default=2_000_000.0,
        help="cover amount in INR (default: 20 lakh, ~400 farmers x 5000)",
    )
    p.add_argument("--start", type=int, default=1995, help="first season year")
    p.add_argument("--end", type=int, default=2024, help="last season year")
    p.add_argument(
        "--trigger-pct",
        type=float,
        default=0.08,
        help="percentile of local history where payout begins",
    )
    p.add_argument(
        "--exit-pct",
        type=float,
        default=0.02,
        help="percentile where full payout is reached",
    )
    p.add_argument("--no-cache", action="store_true", help="bypass the disk cache")
    return p.parse_args()


def main() -> int:
    args = parse_args()
    use_cache = not args.no_cache
    years = range(args.start, args.end + 1)

    print(f"Fetching rainfall history for {YAVATMAL['region']} ...", file=sys.stderr)
    series = fetch_daily_rainfall(
        YAVATMAL["lat"],
        YAVATMAL["lon"],
        date(args.start, 1, 1),
        date(args.end, 12, 31),
        use_cache=use_cache,
    )
    print(f"  {len(series)} daily observations", file=sys.stderr)

    # Calibrate each phase against its own window's distribution.
    thresholds = {
        name: calibrate_thresholds(
            series,
            name,
            start,
            end,
            years,
            trigger_pct=args.trigger_pct,
            exit_pct=args.exit_pct,
        )
        for name, start, end, _weight in PHASE_WINDOWS
    }

    policy = build_policy(thresholds, args.sum_insured)
    result = run_burn(
        policy, args.start, args.end, loading=Loading(), use_cache=use_cache
    )

    render(result)
    path = write_json(result, args)
    print(f"\nWrote {path}", file=sys.stderr)
    return 0


def render(result) -> None:
    policy = result.policy
    si = policy.sum_insured

    print("=" * 72)
    print(f"  PARAMETRIC DROUGHT COVER — QUOTE")
    print("=" * 72)
    print(f"  Region        {policy.region}")
    print(f"  Crop          {policy.crop}")
    print(f"  Cell          {policy.lat:.2f} N, {policy.lon:.2f} E")
    print(f"  Index         {policy.index}")
    print(f"  Sum insured   INR {si:,.0f}")
    print()

    print("  PHASES")
    print(f"  {'phase':<12}{'window':<16}{'weight':>8}{'trigger':>10}{'exit':>8}")
    for p in policy.phases:
        window = f"{p.start} to {p.end}"
        print(
            f"  {p.name:<12}{window:<16}{p.weight:>7.0%}"
            f"{p.trigger_mm:>9.0f}mm{p.exit_mm:>6.0f}mm"
        )
    print()

    print("  BURN ANALYSIS")
    n = len(result.years)
    hits = len(result.payout_years)
    print(f"  Seasons replayed      {n}  ({result.years[0].year}-{result.years[-1].year})")
    print(f"  Seasons with payout   {hits}  ({result.hit_rate:.0%})")
    print(f"  Expected loss         INR {result.expected_loss:,.0f}"
          f"  ({result.expected_loss_rate:.2%} of sum insured)")
    print(f"  Max historical payout INR {result.max_historical_payout:,.0f}")
    print(f"  95th pct payout (VaR) INR {result.value_at_risk(0.95):,.0f}")
    print()

    ld = result.loading
    print("  PREMIUM BUILD-UP")
    print(f"  Expected loss         INR {result.expected_loss:,.0f}")
    print(f"  + capital cost  {ld.capital_cost:>5.0%}   INR {result.expected_loss * ld.capital_cost:,.0f}")
    print(f"  + basis buffer  {ld.basis_risk_buffer:>5.0%}   INR {result.expected_loss * ld.basis_risk_buffer:,.0f}")
    print(f"  + margin        {ld.margin:>5.0%}   INR {result.expected_loss * ld.margin:,.0f}")
    print(f"  + expense       {ld.expense:>5.0%}   INR {result.expected_loss * ld.expense:,.0f}")
    print(f"  {'-' * 44}")
    print(f"  PREMIUM               INR {result.premium:,.0f}"
          f"  ({result.premium_rate:.2%} of sum insured)")
    print()

    print("  YEAR BY YEAR")
    phase_names = [p.name for p in policy.phases]
    header = "  " + f"{'year':<7}" + "".join(f"{n[:9]:>11}" for n in phase_names)
    print(header + f"{'payout':>14}")
    for y in result.years:
        obs = "".join(f"{y.observed_by_phase[n]:>10.0f}m" for n in phase_names)
        flag = "" if y.paid else " "
        payout = f"{y.payout:,.0f}" if y.paid else "-"
        print(f"  {y.year:<7}{obs}{payout:>14}{flag}")
    print()

    worst = result.worst_years(3)
    print("  WORST SEASONS")
    for y in worst:
        if y.paid:
            print(f"  {y.year}: INR {y.payout:,.0f} ({y.payout / si:.0%} of cover)")
    print("=" * 72)


def write_json(result, args) -> Path:
    policy = result.policy
    scale = 10**USDC_DECIMALS

    payload = {
        "policy": {
            "region": policy.region,
            "crop": policy.crop,
            "lat": policy.lat,
            "lon": policy.lon,
            "index": policy.index,
            "sum_insured_inr": policy.sum_insured,
            "phases": [
                {
                    "name": p.name,
                    "start": p.start,
                    "end": p.end,
                    "weight_bps": round(p.weight * 10_000),
                    "trigger_mm_x100": round(p.trigger_mm * 100),
                    "exit_mm_x100": round(p.exit_mm * 100),
                }
                for p in policy.phases
            ],
        },
        "pricing": {
            "seasons": len(result.years),
            "window": [result.years[0].year, result.years[-1].year],
            "expected_loss_inr": round(result.expected_loss, 2),
            "expected_loss_rate": round(result.expected_loss_rate, 6),
            "premium_inr": round(result.premium, 2),
            "premium_rate": round(result.premium_rate, 6),
            "premium_units": round(result.premium * scale / 100),
            "hit_rate": round(result.hit_rate, 4),
            "payout_seasons": len(result.payout_years),
            "max_historical_payout_inr": round(result.max_historical_payout, 2),
            "var95_inr": round(result.value_at_risk(0.95), 2),
            "loading": {
                "capital_cost": result.loading.capital_cost,
                "basis_risk_buffer": result.loading.basis_risk_buffer,
                "margin": result.loading.margin,
                "expense": result.loading.expense,
            },
        },
        "history": [
            {
                "year": y.year,
                "observed_mm": {k: round(v, 1) for k, v in y.observed_by_phase.items()},
                "payout_inr": round(y.payout, 2),
            }
            for y in result.years
        ],
        "provenance": {
            "source": "Open-Meteo ERA5 archive",
            "calibration": {
                "trigger_percentile": args.trigger_pct,
                "exit_percentile": args.exit_pct,
            },
        },
    }

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    path = OUT_DIR / "quote.json"
    path.write_text(json.dumps(payload, indent=2))
    return path


if __name__ == "__main__":
    raise SystemExit(main())
