#!/usr/bin/env python3
"""Trade-off curve: calibration percentile vs premium rate and hit rate.

This is pitch material. A judge asking "where did 150mm come from?" gets shown
this table: the trigger is not a guess, it is a point chosen on a curve, and
the curve is derived from the cell's own 30-year record.

    python tools/sweep_pricing.py
"""

from __future__ import annotations

import sys
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from parametric.burn import Loading, calibrate_thresholds, run_burn  # noqa: E402
from parametric.rainfall import fetch_daily_rainfall  # noqa: E402
from parametric.regions import PHASE_WINDOWS, YAVATMAL, build_policy  # noqa: E402

START, END = 1995, 2024
SUM_INSURED = 2_000_000.0

# (trigger percentile, exit percentile)
GRID = [
    (0.25, 0.05),
    (0.20, 0.05),
    (0.15, 0.04),
    (0.12, 0.03),
    (0.10, 0.02),
    (0.08, 0.02),  # selected default
    (0.06, 0.02),
]
DEFAULT = (0.08, 0.02)


def main() -> int:
    years = range(START, END + 1)
    series = fetch_daily_rainfall(
        YAVATMAL["lat"], YAVATMAL["lon"], date(START, 1, 1), date(END, 12, 31)
    )

    print(f"Calibration sweep — {YAVATMAL['region']}, {START}-{END}")
    print()
    print(
        f"{'trigger':>8}{'exit':>7}{'hit rate':>10}{'exp loss':>10}"
        f"{'premium':>10}{'max payout':>14}"
    )
    print("-" * 59)

    for trigger_pct, exit_pct in GRID:
        thresholds = {
            name: calibrate_thresholds(
                series, name, start, end, years,
                trigger_pct=trigger_pct, exit_pct=exit_pct,
            )
            for name, start, end, _ in PHASE_WINDOWS
        }
        result = run_burn(
            build_policy(thresholds, SUM_INSURED), START, END, loading=Loading()
        )
        mark = "  <- default" if (trigger_pct, exit_pct) == DEFAULT else ""
        print(
            f"{trigger_pct:>8.0%}{exit_pct:>7.0%}{result.hit_rate:>10.0%}"
            f"{result.expected_loss_rate:>10.2%}{result.premium_rate:>10.2%}"
            f"{result.max_historical_payout:>14,.0f}{mark}"
        )

    print()
    print("Real parametric ag products price in the 5-12% band. Above roughly the")
    print("15th percentile the policy pays in most seasons, which makes it a savings")
    print("account with a fee attached rather than risk transfer.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
