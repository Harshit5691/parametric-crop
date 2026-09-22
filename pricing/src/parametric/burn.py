"""Burn analysis: replay a policy against history to price it.

Expected loss = mean historical payout. Premium = expected loss + loading,
where loading covers capital cost, a basis-risk buffer, and margin. This is the
first thing a real parametric underwriter does and it is fully explainable,
which matters more for the pitch than sophistication.

It also answers the demo's closing line directly: "this policy would have paid
out in N of the last M years."
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date
from statistics import mean, quantiles

from .policy import Phase, Policy
from .rainfall import fetch_daily_rainfall


@dataclass(frozen=True)
class Loading:
    """Multiplicative and additive premium loadings, each as a rate.

    Kept separate rather than a single fudge factor so the pitch can defend
    each component on its own.
    """

    capital_cost: float = 0.10  # return demanded by pool LPs on reserved capital
    basis_risk_buffer: float = 0.15  # uncertainty in index-vs-field correlation
    margin: float = 0.10  # protocol take
    expense: float = 0.05  # oracle, ops, off-ramp

    @property
    def total_rate(self) -> float:
        return self.capital_cost + self.basis_risk_buffer + self.margin + self.expense


@dataclass(frozen=True)
class YearResult:
    year: int
    observed_by_phase: dict[str, float]
    payout: float

    @property
    def paid(self) -> bool:
        return self.payout > 0


@dataclass(frozen=True)
class BurnResult:
    policy: Policy
    years: tuple[YearResult, ...]
    loading: Loading

    @property
    def expected_loss(self) -> float:
        return mean(y.payout for y in self.years)

    @property
    def expected_loss_rate(self) -> float:
        return self.expected_loss / self.policy.sum_insured

    @property
    def premium(self) -> float:
        """Risk premium grossed up by loadings."""
        return self.expected_loss * (1 + self.loading.total_rate)

    @property
    def premium_rate(self) -> float:
        return self.premium / self.policy.sum_insured

    @property
    def payout_years(self) -> tuple[YearResult, ...]:
        return tuple(y for y in self.years if y.paid)

    @property
    def hit_rate(self) -> float:
        return len(self.payout_years) / len(self.years)

    @property
    def max_historical_payout(self) -> float:
        return max(y.payout for y in self.years)

    def worst_years(self, n: int = 5) -> tuple[YearResult, ...]:
        return tuple(sorted(self.years, key=lambda y: -y.payout)[:n])

    def value_at_risk(self, percentile: float = 0.95) -> float:
        """Payout level exceeded only (1 - percentile) of the time.

        Used to size how much capital the pool must hold against this policy.
        """
        payouts = sorted(y.payout for y in self.years)
        if len(payouts) < 2:
            return payouts[0] if payouts else 0.0
        idx = min(len(payouts) - 1, int(round(percentile * (len(payouts) - 1))))
        return payouts[idx]


def phase_totals(
    series: dict[date, float], phase: Phase, year: int
) -> float:
    """Cumulative rainfall over a phase window within one year."""
    return sum(
        mm for day, mm in series.items() if day.year == year and phase.covers(day)
    )


def run_burn(
    policy: Policy,
    start_year: int,
    end_year: int,
    *,
    loading: Loading | None = None,
    use_cache: bool = True,
) -> BurnResult:
    """Replay `policy` over each season from start_year to end_year inclusive."""
    if end_year < start_year:
        raise ValueError(f"end_year {end_year} precedes start_year {start_year}")

    series = fetch_daily_rainfall(
        policy.lat,
        policy.lon,
        date(start_year, 1, 1),
        date(end_year, 12, 31),
        use_cache=use_cache,
    )

    years: list[YearResult] = []
    for year in range(start_year, end_year + 1):
        observed = {p.name: phase_totals(series, p, year) for p in policy.phases}
        years.append(
            YearResult(
                year=year,
                observed_by_phase=observed,
                payout=policy.payout(observed),
            )
        )

    return BurnResult(
        policy=policy, years=tuple(years), loading=loading or Loading()
    )


def calibrate_thresholds(
    series: dict[date, float],
    phase_name: str,
    start: str,
    end: str,
    years: range,
    *,
    trigger_pct: float = 0.08,
    exit_pct: float = 0.02,
) -> tuple[float, float]:
    """Derive trigger/exit from the local rainfall distribution.

    The README's 150mm/60mm is illustrative. Applied literally to a wet cell it
    produces a policy that never fires (Yavatmal's flowering window has a ~319mm
    median, so a 150mm trigger hits roughly once in 30 years); applied to a dry
    cell it would fire almost every year and be unaffordable. Anchoring on
    percentiles of the cell's own history gives a defensible, transferable rule
    and is what makes finer grid cells actually worth something.

    Defaults sit deep in the tail on purpose. Calibrating at the 25th percentile
    gives a 63% hit rate and a ~21% premium rate on this cell — which is not
    insurance, it is a savings account with a 40% fee, and no lender buys it.
    The 8th/2nd percentile pair yields a ~30% hit rate at a ~9% premium rate,
    inside the band real parametric ag products occupy (5-12%). `sweep_pricing`
    in tools/ regenerates the full tradeoff curve for the pitch.

    Returns (trigger_mm, exit_mm), rounded to whole mm for clean contract params.
    """
    if not 0 < exit_pct < trigger_pct < 1:
        raise ValueError("require 0 < exit_pct < trigger_pct < 1")

    probe = Phase(
        name=phase_name,
        start=start,
        end=end,
        weight=1.0,
        trigger_mm=1.0,  # placeholder; only `covers` is used below
        exit_mm=0.0,
    )
    totals = sorted(phase_totals(series, probe, y) for y in years)
    if len(totals) < 5:
        raise ValueError(f"need at least 5 years to calibrate, got {len(totals)}")

    # quantiles(n=100) gives the 99 cut points between percentiles.
    cuts = quantiles(totals, n=100, method="inclusive")
    trigger = cuts[int(trigger_pct * 100) - 1]
    exit_mm = cuts[int(exit_pct * 100) - 1]

    trigger_r, exit_r = round(trigger), round(exit_mm)
    if exit_r >= trigger_r:  # degenerate in very low-variance cells
        exit_r = max(0, trigger_r - 1)
    return float(trigger_r), float(exit_r)
