"""Payout math tests.

The payout formula is the one piece of logic that exists twice — here in Python
and again in the Settlement contract. `test_export_vectors` writes the cases to
a shared JSON file that the Solidity test suite reads, so the two
implementations are checked against the same numbers.
"""

from __future__ import annotations

import json
import sys
from datetime import date
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from parametric.burn import YearResult, calibrate_thresholds, phase_totals  # noqa: E402
from parametric.policy import Phase, Policy  # noqa: E402

VECTOR_PATH = Path(__file__).resolve().parents[2] / "contracts" / "test" / "vectors.json"


def make_phase(**kw) -> Phase:
    base = dict(
        name="flowering", start="08-05", end="09-10",
        weight=1.0, trigger_mm=166.0, exit_mm=146.0,
    )
    return Phase(**{**base, **kw})


class TestPhaseValidation:
    def test_rejects_exit_above_trigger(self):
        with pytest.raises(ValueError, match="must be below"):
            make_phase(trigger_mm=100.0, exit_mm=120.0)

    def test_rejects_equal_trigger_and_exit(self):
        with pytest.raises(ValueError, match="must be below"):
            make_phase(trigger_mm=100.0, exit_mm=100.0)

    def test_rejects_negative_exit(self):
        with pytest.raises(ValueError, match="cannot be negative"):
            make_phase(trigger_mm=10.0, exit_mm=-5.0)

    def test_rejects_end_before_start(self):
        with pytest.raises(ValueError, match="must precede"):
            make_phase(start="09-10", end="08-05")

    def test_rejects_weight_out_of_range(self):
        with pytest.raises(ValueError, match="weight"):
            make_phase(weight=1.5)

    def test_rejects_malformed_window(self):
        with pytest.raises(ValueError, match="MM-DD"):
            make_phase(start="august")

    def test_rejects_impossible_month(self):
        with pytest.raises(ValueError, match="valid month"):
            make_phase(start="13-01")


class TestPayoutFraction:
    def test_no_payout_at_trigger(self):
        assert make_phase().payout_fraction(166.0) == 0.0

    def test_no_payout_above_trigger(self):
        assert make_phase().payout_fraction(400.0) == 0.0

    def test_full_payout_at_exit(self):
        assert make_phase().payout_fraction(146.0) == 1.0

    def test_full_payout_below_exit(self):
        assert make_phase().payout_fraction(0.0) == 1.0

    def test_linear_midpoint(self):
        # midway between 146 and 166 is 156
        assert make_phase().payout_fraction(156.0) == pytest.approx(0.5)

    def test_quarter_point(self):
        assert make_phase().payout_fraction(161.0) == pytest.approx(0.25)

    def test_monotonic_decreasing(self):
        phase = make_phase()
        fractions = [phase.payout_fraction(mm) for mm in range(0, 300, 5)]
        assert all(a >= b for a, b in zip(fractions, fractions[1:]))


class TestPhaseCoverage:
    def test_covers_start_and_end_inclusive(self):
        phase = make_phase()
        assert phase.covers(date(2024, 8, 5))
        assert phase.covers(date(2024, 9, 10))

    def test_excludes_outside(self):
        phase = make_phase()
        assert not phase.covers(date(2024, 8, 4))
        assert not phase.covers(date(2024, 9, 11))

    def test_year_agnostic(self):
        phase = make_phase()
        assert phase.covers(date(1995, 8, 20))
        assert phase.covers(date(2024, 8, 20))


class TestPolicy:
    def test_rejects_weights_not_summing_to_one(self):
        with pytest.raises(ValueError, match="sum to 1"):
            Policy(
                region="x", crop="y", lat=0.0, lon=0.0, sum_insured=100.0,
                phases=(make_phase(weight=0.5), make_phase(name="b", weight=0.2)),
            )

    def test_rejects_no_phases(self):
        with pytest.raises(ValueError, match="at least one phase"):
            Policy(region="x", crop="y", lat=0.0, lon=0.0,
                   sum_insured=100.0, phases=())

    def test_rejects_zero_sum_insured(self):
        with pytest.raises(ValueError, match="sum_insured"):
            Policy(region="x", crop="y", lat=0.0, lon=0.0,
                   sum_insured=0.0, phases=(make_phase(),))

    def test_missing_observation_raises(self):
        policy = Policy(region="x", crop="y", lat=0.0, lon=0.0,
                        sum_insured=100.0, phases=(make_phase(),))
        with pytest.raises(KeyError, match="flowering"):
            policy.payout({})

    def test_payout_never_exceeds_sum_insured(self):
        policy = Policy(
            region="x", crop="y", lat=0.0, lon=0.0, sum_insured=1000.0,
            phases=(
                make_phase(name="a", weight=0.6),
                make_phase(name="b", start="09-11", end="10-15", weight=0.4),
            ),
        )
        # total failure in every phase
        assert policy.payout({"a": 0.0, "b": 0.0}) == pytest.approx(1000.0)

    def test_weighted_sum(self):
        policy = Policy(
            region="x", crop="y", lat=0.0, lon=0.0, sum_insured=1000.0,
            phases=(
                make_phase(name="a", weight=0.75),
                make_phase(name="b", start="09-11", end="10-15", weight=0.25),
            ),
        )
        # phase a total failure, phase b untouched
        assert policy.payout({"a": 0.0, "b": 999.0}) == pytest.approx(750.0)


class TestCalibration:
    def _series(self, totals_by_year: dict[int, float]) -> dict[date, float]:
        """Synthesise a series where each year's window holds a known total."""
        series: dict[date, float] = {}
        for year, total in totals_by_year.items():
            series[date(year, 8, 10)] = total
        return series

    def test_trigger_above_exit(self):
        series = self._series({y: float(y % 17) * 30 for y in range(1995, 2025)})
        trigger, exit_mm = calibrate_thresholds(
            series, "flowering", "08-05", "09-10", range(1995, 2025)
        )
        assert trigger > exit_mm

    def test_lower_percentile_gives_lower_trigger(self):
        series = self._series({y: float((y - 1990) * 11 % 400) for y in range(1995, 2025)})
        window = ("flowering", "08-05", "09-10", range(1995, 2025))
        high, _ = calibrate_thresholds(series, *window, trigger_pct=0.25, exit_pct=0.05)
        low, _ = calibrate_thresholds(series, *window, trigger_pct=0.08, exit_pct=0.02)
        assert low <= high

    def test_rejects_bad_percentile_order(self):
        series = self._series({y: 100.0 for y in range(1995, 2025)})
        with pytest.raises(ValueError, match="exit_pct"):
            calibrate_thresholds(
                series, "flowering", "08-05", "09-10", range(1995, 2025),
                trigger_pct=0.02, exit_pct=0.08,
            )

    def test_rejects_too_few_years(self):
        series = self._series({y: 100.0 for y in range(2020, 2023)})
        with pytest.raises(ValueError, match="at least 5 years"):
            calibrate_thresholds(
                series, "flowering", "08-05", "09-10", range(2020, 2023)
            )

    def test_constant_series_still_yields_valid_phase(self):
        """A zero-variance cell must not produce trigger == exit."""
        series = self._series({y: 200.0 for y in range(1995, 2025)})
        trigger, exit_mm = calibrate_thresholds(
            series, "flowering", "08-05", "09-10", range(1995, 2025)
        )
        assert exit_mm < trigger
        Phase(name="f", start="08-05", end="09-10", weight=1.0,
              trigger_mm=trigger, exit_mm=exit_mm)  # must not raise


class TestPhaseTotals:
    def test_sums_only_in_window_and_year(self):
        phase = make_phase()
        series = {
            date(2024, 8, 10): 50.0,   # in
            date(2024, 9, 1): 25.0,    # in
            date(2024, 7, 1): 999.0,   # out of window
            date(2023, 8, 10): 999.0,  # wrong year
        }
        assert phase_totals(series, phase, 2024) == pytest.approx(75.0)

    def test_empty_window_is_zero(self):
        assert phase_totals({}, make_phase(), 2024) == 0.0


def test_export_vectors():
    """Write cross-implementation vectors for the Solidity test suite."""
    phase = make_phase()
    cases = []
    for observed in [0.0, 100.0, 146.0, 150.0, 156.0, 161.0, 166.0, 200.0, 400.0]:
        cases.append(
            {
                "trigger_mm_x100": round(phase.trigger_mm * 100),
                "exit_mm_x100": round(phase.exit_mm * 100),
                "observed_mm_x100": round(observed * 100),
                "weight_bps": round(phase.weight * 10_000),
                "sum_insured_units": 1_000_000,
                "expected_payout_units": round(
                    phase.payout(1_000_000, observed)
                ),
            }
        )

    VECTOR_PATH.parent.mkdir(parents=True, exist_ok=True)
    # `count` is emitted explicitly: forge-std cannot read an array's length
    # from JSON, and the generator already knows it.
    VECTOR_PATH.write_text(
        json.dumps({"count": len(cases), "payout_cases": cases}, indent=2)
    )
    assert VECTOR_PATH.exists()
    # sanity: the boundary cases must bracket the range
    assert cases[0]["expected_payout_units"] == 1_000_000
    assert cases[-1]["expected_payout_units"] == 0
