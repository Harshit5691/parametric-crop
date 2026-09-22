"""Demo region and crop calendar.

Yavatmal, Vidarbha, Maharashtra — kharif soybean. Chosen because it is a real
soybean belt with real lender distress, and because Open-Meteo has complete
daily coverage there back to the 1990s (verified: 10,958/10,958 days for
1995-2024, zero nulls).

Crop calendar for kharif soybean in Vidarbha, sown on monsoon onset:
  sowing/germination  mid-Jun -> late Jul   — needs establishing rain
  flowering/pod-fill  early Aug -> mid-Sep  — most yield-sensitive phase
  maturity            mid-Sep -> mid-Oct    — less sensitive; excess hurts more

Weights concentrate exposure on flowering, per the brief's phase-weighted design.
"""

from __future__ import annotations

from .policy import Phase, Policy

YAVATMAL = {
    "region": "Yavatmal, Vidarbha, Maharashtra",
    "lat": 20.39,
    "lon": 78.13,
}

# Window bounds as MM-DD; thresholds are filled in by calibration.
PHASE_WINDOWS = (
    ("sowing", "06-15", "07-31", 0.25),
    ("flowering", "08-05", "09-10", 0.55),
    ("maturity", "09-11", "10-15", 0.20),
)


def build_policy(
    thresholds: dict[str, tuple[float, float]],
    sum_insured: float,
) -> Policy:
    """Assemble the demo policy from calibrated thresholds.

    `thresholds` maps phase name -> (trigger_mm, exit_mm).
    """
    phases = tuple(
        Phase(
            name=name,
            start=start,
            end=end,
            weight=weight,
            trigger_mm=thresholds[name][0],
            exit_mm=thresholds[name][1],
        )
        for name, start, end, weight in PHASE_WINDOWS
    )
    return Policy(
        region=YAVATMAL["region"],
        crop="kharif soybean",
        lat=YAVATMAL["lat"],
        lon=YAVATMAL["lon"],
        phases=phases,
        sum_insured=sum_insured,
    )
