# Pricing decisions

Running record of choices the pitch has to defend. Written as we make them so
the demo and the deck do not drift from the code.

---

## 1. Triggers are calibrated, not hardcoded

**Decision:** trigger and exit thresholds are derived per phase from the
percentile distribution of that grid cell's own rainfall history, not written
into the policy by hand.

**Why.** The brief's worked example — trigger 150 mm, exit 60 mm over a
flowering window — is illustrative, and applying it literally to the demo cell
produces a broken product. Yavatmal's Aug 5 – Sep 10 window has a **median of
319 mm** across 1995–2024. A 150 mm trigger fires in **1 season out of 30** and
never reaches full payout. The burn analysis would show a near-zero expected
loss, the premium would round to nothing, and the demo's live payout moment
would never fire on real data.

The inverse failure is just as real: the same 150 mm applied to a genuinely
arid cell would fire nearly every year and be unaffordable.

**Consequence.** Percentile calibration is what makes "finer grid cells" an
actual differentiator rather than a slogan. A district-level product has to
pick one threshold for a whole district; a per-cell product can put each cell's
trigger at the same point in its *own* distribution. That is the mechanism by
which granularity reduces basis risk, and it is worth saying that way in the
pitch.

---

## 2. Calibration sits deep in the tail — 8th/2nd percentile

**Decision:** default `trigger_pct = 0.08`, `exit_pct = 0.02`.

**Why.** The first calibration attempt used the 25th/5th percentiles, which
seemed conservative. It priced out at a **20.6% premium rate with a 63% hit
rate** — the policy paid in nearly two seasons out of three, including seasons
like 2009 (274 mm in flowering, an ordinary year) that paid a token ₹2,857.

A policy that pays in most years is not risk transfer. It is a savings account
with a ~40% fee attached, since the loading is charged on every one of those
frequent small payouts. No agri-lender buys that, and a judge who knows
insurance will spot it immediately.

Sweeping the percentile (`tools/sweep_pricing.py`) gives the trade-off curve:

| trigger pct | hit rate | expected loss | premium rate |
|---|---|---|---|
| 25% | 63% | 14.70% | 20.57% |
| 20% | 53% | 12.80% | 17.93% |
| 15% | 47% | 10.27% | 14.38% |
| 12% | 37% | 8.71% | 12.20% |
| 10% | 30% | 7.46% | 10.44% |
| **8%** | **30%** | **6.52%** | **9.12%** |
| 6% | 20% | 5.10% | 7.15% |

8%/2% lands at a **9.1% premium rate** — inside the 5–12% band real parametric
agriculture products occupy — while still paying in **9 of the last 30
seasons**, which is frequent enough that the cover visibly matters.

**For the pitch:** this table is the answer to "where did your threshold come
from?" The trigger is a point chosen on a curve derived from 30 years of the
cell's own record, not a number someone picked.

---

## 3. Phase weights concentrate on flowering

**Decision:** sowing 25%, flowering 55%, maturity 20%.

**Why.** Soybean yield in Vidarbha is most sensitive to moisture stress during
flowering and pod-fill. Weighting exposure toward that window is what the
brief's phase-weighted design is for, and it means a dry August hurts the
payout far more than a dry October — matching how the crop actually fails.

**Open:** these weights are agronomic judgement, not fitted to yield data. If
we get district yield series from a partner, fit them and say so. Until then
the pitch should call them what they are.

---

## 4. Single source for pricing, multi-source for settlement

**Decision:** pricing uses Open-Meteo's ERA5 archive alone. The multi-source
median the brief calls for belongs in the settlement oracle.

**Why.** These are different jobs. Pricing needs a long, internally consistent
record — mixing sources across a 30-year window introduces discontinuities that
corrupt the distribution the thresholds are calibrated against. Settlement
needs tamper-resistance at a single point in time, which is what medianing
across feeds buys.

**Risk to state plainly:** if the settlement oracle's sources disagree
systematically with ERA5, the policy is priced off one distribution and settled
against another. Before launch, backtest the settlement feed against ERA5 over
the same window and disclose the gap. This is a real exposure, not a detail.

---

## 5. Data provenance

Open-Meteo ERA5 archive, cell 20.39 N / 78.13 E, 1995–2024.
**10,958 of 10,958 daily observations present, zero nulls.**

Responses are cached under `pricing/data/cache/` so the burn analysis is
reproducible offline and the demo never depends on a live API call.
