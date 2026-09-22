"""Policy definition and payout math.

This module is the single source of truth for what a policy *is*. The Solidity
Settlement contract reimplements `phase_payout` in fixed-point integers; any
change to the formula here has to be mirrored there, and `tests/` checks the two
agree on a shared vector file.
"""

from __future__ import annotations

from dataclasses import dataclass, field, asdict
from datetime import date
from typing import Any


# Payouts are carried as floats through the pricing engine (readability) and
# converted to 6-decimal integers at the contract boundary, matching USDC.
USDC_DECIMALS = 6


def _mmdd(d: str) -> str:
    """Validate and normalise an "MM-DD" window bound."""
    parts = d.split("-")
    if len(parts) != 2 or not all(p.isdigit() for p in parts):
        raise ValueError(f"expected MM-DD, got {d!r}")
    month, day = int(parts[0]), int(parts[1])
    if not (1 <= month <= 12 and 1 <= day <= 31):
        raise ValueError(f"not a valid month/day: {d!r}")
    return f"{month:02d}-{day:02d}"


@dataclass(frozen=True)
class Phase:
    """One window of the crop calendar.

    Windows are given as MM-DD so a single policy template can be replayed
    against any year of history. `weight` is the share of sum insured exposed
    during this phase; weights across a policy must sum to 1.
    """

    name: str
    start: str  # MM-DD
    end: str  # MM-DD
    weight: float
    trigger_mm: float  # payout starts below this cumulative rainfall
    exit_mm: float  # full phase payout at or below this

    def __post_init__(self) -> None:
        object.__setattr__(self, "start", _mmdd(self.start))
        object.__setattr__(self, "end", _mmdd(self.end))
        if self.start >= self.end:
            raise ValueError(
                f"phase {self.name!r}: start {self.start} must precede end {self.end}"
            )
        if not 0 < self.weight <= 1:
            raise ValueError(f"phase {self.name!r}: weight must be in (0, 1]")
        if self.exit_mm >= self.trigger_mm:
            raise ValueError(
                f"phase {self.name!r}: exit {self.exit_mm} must be below "
                f"trigger {self.trigger_mm}"
            )
        if self.exit_mm < 0:
            raise ValueError(f"phase {self.name!r}: exit cannot be negative")

    def covers(self, day: date) -> bool:
        return self.start <= f"{day.month:02d}-{day.day:02d}" <= self.end

    def payout_fraction(self, observed_mm: float) -> float:
        """Share of this phase's exposure that pays out, in [0, 1].

        Linear between trigger and exit, per the brief:
            clamp((trigger - observed) / (trigger - exit), 0, 1)
        """
        span = self.trigger_mm - self.exit_mm
        raw = (self.trigger_mm - observed_mm) / span
        return min(1.0, max(0.0, raw))

    def payout(self, sum_insured: float, observed_mm: float) -> float:
        return sum_insured * self.weight * self.payout_fraction(observed_mm)


@dataclass(frozen=True)
class Policy:
    """A parametric drought policy for one region/crop/season."""

    region: str
    crop: str
    lat: float
    lon: float
    phases: tuple[Phase, ...]
    sum_insured: float
    index: str = "cumulative_rainfall_mm"

    def __post_init__(self) -> None:
        if not self.phases:
            raise ValueError("policy needs at least one phase")
        total = sum(p.weight for p in self.phases)
        if abs(total - 1.0) > 1e-9:
            raise ValueError(f"phase weights must sum to 1, got {total}")
        if self.sum_insured <= 0:
            raise ValueError("sum_insured must be positive")

    @property
    def max_payout(self) -> float:
        """Worst case across all phases — what the pool must reserve."""
        return self.sum_insured

    def payout(self, observed_by_phase: dict[str, float]) -> float:
        """Total payout given each phase's observed cumulative rainfall."""
        missing = {p.name for p in self.phases} - observed_by_phase.keys()
        if missing:
            raise KeyError(f"no observation for phase(s): {sorted(missing)}")
        return sum(
            p.payout(self.sum_insured, observed_by_phase[p.name]) for p in self.phases
        )

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)
