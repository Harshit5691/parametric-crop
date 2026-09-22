import { usePool } from "../hooks/usePool";
import { formatBps, formatPct, formatUsdc } from "../lib/format";

/// The solvency panel — the buyer's answer to "can they actually pay?"
///
/// An opaque insurer asks you to trust its balance sheet. These four numbers
/// come straight from the chain, so the buyer verifies rather than trusts.
export function PoolStatus() {
  const pool = usePool();

  if (pool.isLoading || pool.totalAssets === undefined) {
    return (
      <section className="pool">
        <h3>Backing pool</h3>
        <p className="muted">Reading chain…</p>
      </section>
    );
  }

  const fullyBacked =
    pool.totalReserved !== undefined &&
    pool.capacity !== undefined &&
    pool.totalReserved <= pool.capacity;

  return (
    <section className="pool">
      <div className="pool__head">
        <h3>Backing pool</h3>
        <span className={`badge badge--${fullyBacked ? "safe" : "alert"}`}>
          {fullyBacked ? "Fully collateralised" : "Under-collateralised"}
        </span>
      </div>

      <dl className="pool__stats">
        <div>
          <dt>Capital</dt>
          <dd>{formatUsdc(pool.totalAssets, { compact: true })} USDC</dd>
        </div>
        <div>
          <dt>Active exposure</dt>
          <dd>{formatUsdc(pool.totalReserved ?? 0n, { compact: true })} USDC</dd>
        </div>
        <div>
          <dt>Utilisation</dt>
          <dd>{formatPct(pool.utilisation)}</dd>
        </div>
        <div>
          <dt>Solvency ratio</dt>
          <dd>{formatBps(pool.solvencyRatioBps ?? 0)}</dd>
        </div>
      </dl>

      <div className="pool__bar" title={`${formatPct(pool.utilisation)} utilised`}>
        <div
          className="pool__bar-fill"
          style={{ width: `${Math.min(100, pool.utilisation * 100)}%` }}
        />
      </div>
      <p className="muted pool__note">
        Exposure can never exceed capital × solvency ratio — enforced onchain,
        verifiable by anyone.
      </p>
    </section>
  );
}
