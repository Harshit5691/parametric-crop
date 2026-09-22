# Dashboards

Buyer-facing dashboard — React + Vite + wagmi, reading live chain state.

**Status:** working. Verified against a local anvil chain end to end, including
the payout landing live when settlement fires.

## Run it

Needs a chain with the contracts deployed and a policy written:

```bash
# terminal 1 — chain
anvil

# terminal 2 — deploy + write the demo policy
cd ../contracts
forge script script/Demo.s.sol:DemoSetup \
  --rpc-url http://localhost:8545 --broadcast --unlocked \
  --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266

# terminal 3 — dashboard
npm install
npm run dev            # http://localhost:5173
```

The addresses come from `src/contracts/addresses.json`. `Demo.s.sol` prints the
deployed addresses; `Deploy.s.sol` writes that file directly. **Anvil hands out
different addresses depending on nonce order, so regenerate rather than assume
the file is current** — a stale address shows up as "No policy found onchain".

### Watching the payout land

With the dashboard open, advance the chain past the crop windows and settle:

```bash
cd ../contracts
cast rpc evm_increaseTime 11232000 --rpc-url http://localhost:8545
cast rpc evm_mine --rpc-url http://localhost:8545

POOL=0x... MANAGER=0x... POLICY_ID=1 \
forge script script/Demo.s.sol:DemoSettle \
  --rpc-url http://localhost:8545 --broadcast --unlocked --sender $SENDER
```

The dashboard re-reads on every block, so the payout, the phase badges and the
pool balance update without a refresh. That is demo step 4.

## Regenerating contract bindings

After any contract change:

```bash
cd ../contracts && ./script/export-abis.sh
```

Writes `src/contracts/*Abi.ts`. The `as const` in those files is what gives
wagmi its types — without it every read comes back untyped.

## What it shows

**Policy summary** — sum insured, premium and its rate, total paid, phases
settled.

**Crop calendar** — one card per phase with a gauge showing where the rainfall
index sits against that phase's trigger and exit. The trigger–exit band occupies
the middle 70% of each track, so a reading far above the trigger still reads
differently from a marginal one; clamping everything outside the band to the
edge made a comfortable 547 mm look identical to a marginal 293 mm.

**Backing pool** — capital, active exposure, utilisation, solvency ratio, read
straight from the chain. This is the transparency claim made concrete: the
buyer verifies the book is backed instead of trusting a balance sheet.

**Burn analysis** — the 30-season payout history from the pricing engine.
Imported from `pricing/out/quote.json` through the `@pricing` alias rather than
a copy, so re-running `python quote.py` updates the dashboard.

## Known gaps

- **Read-only.** No wallet transactions — you cannot buy a policy or deposit as
  an LP from the UI. Everything is driven by forge scripts.
- **LP dashboard not built.** Demo step 5 (pool balance, exposure, yield from
  the LP's side) still needs its own view; `PoolStatus` covers part of it.
- **Policy #1 is hardcoded.** No policy list or selector.
- **Phase windows are display-only.** The onchain windows are anchored to
  deploy time so the demo can fast-forward through them, which makes the raw
  timestamps read as a future season. The UI shows the fixed agronomic calendar
  and labels the replayed season explicitly, so nothing is presented as live
  current-season data.

## First run after a clone

`src/contracts/addresses.json` is gitignored — it holds whatever addresses your
local chain produced, which are machine-specific. Create it before the first
build:

```bash
cp src/contracts/addresses.example.json src/contracts/addresses.json
```

Then run `Deploy.s.sol` (or copy the addresses `Demo.s.sol` prints) to fill it
in. The generated `*Abi.ts` files are committed, so ABIs work straight away.
