"""Historical rainfall retrieval.

Open-Meteo's archive API is the prototyping source (free, no key, daily data
back to 1940). The brief calls for a multi-source median at settlement time;
that belongs in the oracle service, not here. This module is for *pricing*,
where a single well-documented reanalysis source is defensible as long as the
pitch says which one it is.

Responses are cached on disk keyed by (lat, lon, range) so a burn analysis can
be re-run offline and the demo never depends on a live API call.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.parse
import urllib.request
from datetime import date, datetime
from pathlib import Path

ARCHIVE_URL = "https://archive-api.open-meteo.com/v1/archive"
CACHE_DIR = Path(__file__).resolve().parents[2] / "data" / "cache"

# Open-Meteo's archive lags real time by ~5 days; asking beyond that yields nulls.
ARCHIVE_LAG_DAYS = 5


class RainfallError(RuntimeError):
    pass


def _cache_path(lat: float, lon: float, start: date, end: date) -> Path:
    key = f"{lat:.4f}_{lon:.4f}_{start.isoformat()}_{end.isoformat()}.json"
    return CACHE_DIR / key


def fetch_daily_rainfall(
    lat: float,
    lon: float,
    start: date,
    end: date,
    *,
    use_cache: bool = True,
    timeout: int = 120,
) -> dict[date, float]:
    """Daily precipitation in mm, keyed by date.

    Missing days are returned as 0.0 but counted; callers that care about data
    quality should use `coverage_report`.
    """
    if start > end:
        raise ValueError(f"start {start} is after end {end}")

    path = _cache_path(lat, lon, start, end)
    payload: dict | None = None

    if use_cache and path.exists():
        try:
            payload = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError):
            payload = None  # corrupt cache entry: refetch

    if payload is None:
        query = urllib.parse.urlencode(
            {
                "latitude": f"{lat:.4f}",
                "longitude": f"{lon:.4f}",
                "start_date": start.isoformat(),
                "end_date": end.isoformat(),
                "daily": "precipitation_sum",
                "timezone": "Asia/Kolkata",
            }
        )
        url = f"{ARCHIVE_URL}?{query}"
        try:
            with urllib.request.urlopen(url, timeout=timeout) as resp:
                payload = json.load(resp)
        except urllib.error.HTTPError as exc:
            raise RainfallError(
                f"Open-Meteo returned {exc.code} for {lat},{lon} "
                f"{start}..{end}: {exc.read()[:200]!r}"
            ) from exc
        except (urllib.error.URLError, TimeoutError) as exc:
            raise RainfallError(
                f"could not reach Open-Meteo for {lat},{lon}: {exc}"
            ) from exc

        if use_cache:
            CACHE_DIR.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(payload))

    daily = payload.get("daily") or {}
    times, sums = daily.get("time"), daily.get("precipitation_sum")
    if not times or sums is None:
        raise RainfallError(
            f"malformed Open-Meteo response for {lat},{lon}: keys={list(payload)}"
        )

    return {
        datetime.strptime(t, "%Y-%m-%d").date(): (v if v is not None else 0.0)
        for t, v in zip(times, sums)
    }


def coverage_report(
    series: dict[date, float], start: date, end: date
) -> dict[str, int]:
    """How complete a series is — surfaced in the pricing report."""
    expected = (end - start).days + 1
    present = sum(1 for d in series if start <= d <= end)
    return {
        "expected_days": expected,
        "present_days": present,
        "missing_days": expected - present,
    }
