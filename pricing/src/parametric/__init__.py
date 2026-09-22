"""Parametric crop protection — pricing engine."""

from .burn import BurnResult, Loading, YearResult, calibrate_thresholds, run_burn
from .policy import Phase, Policy
from .rainfall import fetch_daily_rainfall

__all__ = [
    "BurnResult",
    "Loading",
    "Phase",
    "Policy",
    "YearResult",
    "calibrate_thresholds",
    "fetch_daily_rainfall",
    "run_burn",
]
