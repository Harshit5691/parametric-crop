# Parametric Crop Protection — Project Brief

Positioning line: **"Drought cover that pays in days, not months — no claim, no adjuster."**

---

## The problem

Smallholder farmers carry almost all of their weather risk personally. One failed
monsoon wipes out a season's income, which becomes debt, which becomes distress
selling of land or livestock.

Traditional crop insurance fails them on economics: someone has to visit the field,
assess the loss, and process a claim — and that costs more than a ₹500–2,000 policy
is worth. So claims are slow, disputed, and frequently never paid.

## The mechanism

Parametric insurance skips loss assessment entirely. The policy pays on an
**objective index**, not on proven damage:

> If cumulative rainfall in district X during the crop's flowering window falls
> below 150 mm, pay out. The farther below, the bigger the payout.

No claim is filed. No adjuster visits. The data crosses the threshold and the money moves.

## Be honest about what's not new

Parametric weather cover already exists in India — the government's **RWCIS**
(Restructured Weather Based Crop Insurance Scheme) runs alongside **PMFBY**. So
"parametric" is not the innovation, and a judge who knows the space will say so.

Our differentiation has to be:
1. **Speed** — payout within days of the trigger window closing, not months
2. **Granularity** — finer grid cells than district-level, which reduces basis risk
3. **Transparency** — trigger, data, pool balance, and every payout publicly verifiable
4. **Capital** — a new source of underwriting capital (see next section)

Lead the pitch with these, not with "parametric insurance on blockchain."

---

## Why crypto is load-bearing (the real answer)

The weak answer is "smart contracts automate payouts." A bank can do that too.

The strong answer is **capital**. Onchain there's a large pool of stablecoin capital
hunting for yield, and nearly all of it is correlated with crypto markets. Monsoon
failure in Maharashtra is **uncorrelated with the price of ETH**. Weather risk is one
of the few genuinely uncorrelated yield sources that exists.

So the two-sided story is:
- **Farmers/FPOs** get cheap, fast cover they can't get elsewhere
- **Onchain LPs** get yield uncorrelated with everything else they hold

Plus: the pool is fully collateralised and publicly auditable — the insurer can't
be insolvent without everyone seeing it. That's a real trust improvement over an
opaque insurer, and it's the thing a normal database cannot provide.

---

## Who the customer is — not the farmer

Do not sell to individual farmers. They can't onboard to crypto, you can't reach them
in four weeks, and the unit economics per policy don't work.

Sell to the **aggregator** who already carries the risk:

| Buyer | Why they'd pay |
|---|---|
| **FPOs / co-ops** (Farmer Producer Organisations) | Buy one policy covering 500 members; protects the group's ability to repay input loans |
| **Agri-lenders / MFIs** | A drought means their loan book defaults. Cover protects the portfolio — strongest buyer |
| **Input companies** (seed, fertiliser on credit) | Same exposure as lenders |
| **Contract farming buyers** | Protects their supply commitments |

**Agri-lenders are the sharpest wedge**: they understand risk, have budget, have the
farmer relationships, and the thing they're insuring (their own loan book) is
already financial.

Farmers still benefit — the payout flows to the FPO/lender and on to members via
UPI or loan relief — but they never touch a wallet.

---

## Regulatory reality — read this before building

Selling insurance in India requires an **IRDAI** licence. We don't have one and
won't get one in four weeks.

Options, in rough order of realism:
1. **Partner model** — a licensed insurer or reinsurer fronts the policy; we are the
   technology, pricing, and capital layer behind it. How most insurtechs start.
2. **Risk-transfer contract to a business, not a person** — covering an agri-lender's
   loan book is a B2B financial arrangement; structure matters and needs a lawyer.
3. **Launch outside India first** — markets with more permissive regimes for
   parametric pilots.

For the hackathon: **build and demo the protocol, and state the go-to-market
licensing path plainly in the pitch.** Pretending the regulation doesn't exist is the
fastest way to lose credibility with judges.

---

## Trigger design

A policy is defined by:

```
Policy {
  region,            // grid cell or district polygon
  crop,              // e.g. kharif soybean
  phases: [          // crop calendar split into windows
    { name: "sowing",    start, end, weight },
    { name: "flowering", start, end, weight },   // usually most sensitive
    { name: "maturity",  start, end, weight }
  ],
  index: "cumulative_rainfall_mm",
  trigger: 150,      // payout starts below this
  exit:    60,       // full payout at or below this
  sum_insured,
  premium
}
```

Payout is **linear between trigger and exit**:

```
payout = sum_insured × phase_weight × clamp((trigger − observed) / (trigger − exit), 0, 1)
```

Add an **excess rainfall** index later (floods), and a consecutive-dry-days index
(a dry spell mid-season can kill a crop even if total rainfall looks fine).

### Pricing — burn analysis
Replay the policy against 20–30 years of historical rainfall for that cell.
- Expected loss = mean historical payout
- Premium = expected loss + loading (capital cost, basis-risk buffer, margin)

This is simple, explainable, and exactly what real parametric underwriters do first.
It also makes a great demo panel: *"here's what this policy would have paid in each
of the last 25 years."*

---

## Data / oracle sources

| Source | What | Notes |
|---|---|---|
| **CHIRPS** | Satellite+station rainfall, ~5 km grid, daily, back to 1981 | Standard for parametric ag; good for pricing history |
| **ERA5** (Copernicus) | Reanalysis, global | Long history, coarser |
| **NASA POWER** | Agro-climatology API | Easy API, good for prototyping |
| **IMD** | India Meteorological Department gridded rainfall | Authoritative for India; access can be clunky |
| **Open-Meteo** | Free weather API incl. historical | Fastest to prototype against |

**Oracle design:** never trust one feed. Pull 2–3 sources, take the median, publish
the inputs and the result. Use Chainlink Functions / Switchboard or a signed
multi-source oracle we operate. Be explicit that the oracle is the trust assumption —
if we run it, we're a trusted party, and the pitch should say how that decentralises
over time.

Later: satellite vegetation indices (NDVI) as a second, crop-outcome-based index.

---

## Basis risk — the unavoidable weakness

Basis risk = the index says one thing, the farmer's field experienced another. The
station recorded rain; this particular field got none. The farmer lost the crop and
got nothing.

Every parametric product has this. It's the #1 reason farmers distrust them. Mitigate:
- Finer grid cells (5 km CHIRPS beats district averages)
- Multiple indices (rainfall + dry spells + NDVI)
- Phase-weighted triggers matched to the actual crop calendar
- Show historical correlation between the index and real yield data where available

**Acknowledge it in the pitch.** A judge will ask. "We know, here's how we shrink it"
is a strong answer; silence is a fatal one.

---

## Architecture

### Contracts
1. **Pool** — LPs deposit stablecoins, receive pool shares. Premiums flow in; payouts
   flow out. Enforce a solvency rule: total active max-payout ≤ pool capital × ratio.
2. **Policy** — created by an approved buyer (FPO/lender), holds trigger params,
   premium paid upfront, active window.
3. **Settlement** — at the end of each phase window, reads the oracle value, computes
   payout per formula, transfers to the buyer. Permissionless to call.

### Off-chain
- Pricing engine (burn analysis over historical data) → quotes premium
- Oracle service (multi-source fetch, median, sign, post)
- Buyer dashboard: create policy, see live index vs trigger, see payouts
- LP dashboard: pool capital, active exposure, historical returns
- Off-ramp: stablecoin payout → INR to FPO bank → UPI to members

### Chain
Open question. Needs cheap transactions, good stablecoin liquidity, a reliable
oracle network. Solana and Base are both reasonable.

---

## The demo — this project's biggest advantage

Strongest demo of any idea on the list. Script:
1. Show an FPO in Vidarbha: 400 soybean farmers, one policy, premium paid
2. Show the live rainfall index tracking below-normal through the flowering window
3. Advance to window close (demo mode lets us fast-forward the oracle)
4. Index crosses the trigger → payout fires automatically → money lands in the FPO
   wallet → show the INR/UPI distribution step
5. Cut to the LP side: pool balance, exposure, yield
6. Close on burn analysis: "this policy would have paid out in 7 of the last 25 years"

Under two minutes. No human touched the money.

---

## Four-week plan (Sept 14 – Oct 12, team of 2)

**Week 1 — pricing + trigger**
Pull CHIRPS/Open-Meteo history for 2–3 real regions. Build burn analysis, produce a
real premium quote for a real crop calendar. In parallel: contact FPOs, agri-lenders,
MFIs. Goal: 3 conversations, ideally one willing to be named as a design partner.

**Week 2 — contracts**
Pool, policy, settlement contracts. Oracle service posting median values. End-to-end
on testnet: create policy → force trigger → payout.

**Week 3 — dashboards + real data**
Buyer and LP dashboards. Wire in live rainfall for the current season (Sept–Oct is
late kharif / early rabi — check which crop windows are actually live). A real
partner quoting a real policy, even if not funded.

**Week 4 — freeze and pitch**
Feature freeze **Oct 8**. Demo video, write-up, regulatory path slide, basis-risk slide.

### Split
- **Person A:** contracts, oracle service, settlement
- **Person B:** pricing engine, dashboards, partner conversations

---

## Cut list

Multiple indices beyond rainfall · NDVI · floods · secondary market for policies ·
a token · governance · individual farmer onboarding · mobile app · real reinsurance
integration · multiple chains

---

## What decides the outcome

1. A real FPO or lender who says, on record, "we'd buy this"
2. A burn analysis on real historical data — proves the pricing isn't made up
3. The live payout moment in the demo
4. A credible, honest answer on regulation and basis risk

The known weakness: **capital**. We can't underwrite a real pool in four weeks. Demo
with a small self-funded testnet pool, and pitch the LP side as the scaling path.

---

## Hackathon context

Colosseum Crypto World's Fair, Sept 14 – Oct 12 2026. Online, open across ecosystems
(Solana, Ethereum, Hyperliquid, Base, Tempo, Arbitrum, Zcash, Robinhood Chain).
Judged as startups; winners are interviewed for Colosseum's accelerator,
historically $250K pre-seed per team.

---

## Open questions to resolve early

1. Which chain — Solana or Base?
2. Which region and crop for the demo? Pick one with good data and a real partner.
3. Lender or FPO as the lead buyer persona?
4. Which crop windows are actually live during Sept–Oct, so the demo can use real
   current-season data rather than only historical replay?
5. Who runs the oracle at launch, and what's the decentralisation story?

---

## Working preferences

- Push back on scope creep. Four weeks, two people.
- One working path end to end beats breadth.
- Flag when a decision makes the onchain component decorative — the capital and
  transparency story must stay central.
- Never hide basis risk or regulation; surface them early.
