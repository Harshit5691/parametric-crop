# Pricing engine

Burn analysis over historical rainfall → a defensible premium quote.

## Setup

```bash
python3 -m venv .venv
.venv/bin/pip install pytest        # only needed for tests
```

No runtime dependencies beyond the standard library.

## Quote the demo policy

```bash
python3 quote.py
```

Prints the pricing panel used in the demo and writes `out/quote.json` for the
contracts and dashboards to consume.

Options:

```bash
python3 quote.py --sum-insured 5000000     # cover amount in INR
python3 quote.py --start 1990 --end 2024   # history window
python3 quote.py --trigger-pct 0.10        # calibration percentiles
python3 quote.py --no-cache                # bypass the disk cache
```

## Calibration sweep

```bash
python3 tools/sweep_pricing.py
```

Regenerates the trigger-percentile trade-off curve. This is the answer to
"where did your threshold come from?" — see [docs/pricing-decisions.md](../docs/pricing-decisions.md).

## Tests

```bash
../.venv/bin/python -m pytest tests/ -q
```

`test_export_vectors` writes `contracts/test/vectors.json`, the shared cases the
Solidity Settlement test suite checks its fixed-point payout math against. The
payout formula exists in two languages; these vectors are what keeps them
agreeing.

## Layout

```
src/parametric/
  policy.py     Policy/Phase definitions and the payout formula
  rainfall.py   Open-Meteo archive client with on-disk caching
  burn.py       Burn analysis, loadings, threshold calibration
  regions.py    Demo region and crop calendar
quote.py        CLI: quote + JSON artefact
tools/          Analysis scripts that back pitch claims
```

## Current numbers

Yavatmal, Vidarbha — kharif soybean, ₹20 lakh cover, 1995–2024:

- Premium **₹182,426** (9.12% of sum insured)
- Expected loss 6.52%, hit rate 30% — pays in **9 of 30 seasons**
- Worst season 2005: ₹1,100,000 (55% of cover)
