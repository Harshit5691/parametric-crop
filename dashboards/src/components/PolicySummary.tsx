import type { Policy } from "../hooks/usePolicy";
import { formatUsdc, shortAddress } from "../lib/format";

type Props = {
  policyId: bigint;
  policy: Policy;
  region: string;
  crop: string;
};

export function PolicySummary({ policyId, policy, region, crop }: Props) {
  const premiumRate =
    policy.sumInsuredUnits > 0n
      ? Number(policy.premiumUnits) / Number(policy.sumInsuredUnits)
      : 0;

  return (
    <section className="summary">
      <div className="summary__title">
        <div>
          <p className="eyebrow">Policy #{policyId.toString()}</p>
          <h2>{region}</h2>
          <p className="summary__crop">
            {crop} · cumulative rainfall index
          </p>
          <p className="summary__season">
            Replaying the <strong>2005 kharif season</strong> — the worst in the
            30-year record
          </p>
        </div>
        {policy.closed && <span className="badge badge--closed">Season closed</span>}
      </div>

      <dl className="summary__stats">
        <div>
          <dt>Sum insured</dt>
          <dd>{formatUsdc(policy.sumInsuredUnits, { compact: true })} USDC</dd>
        </div>
        <div>
          <dt>Premium paid</dt>
          <dd>
            {formatUsdc(policy.premiumUnits, { compact: true })} USDC
            <span className="dd-note">{(premiumRate * 100).toFixed(2)}% rate</span>
          </dd>
        </div>
        <div>
          <dt>Paid out</dt>
          <dd className={policy.totalPaidUnits > 0n ? "is-payout" : ""}>
            {formatUsdc(policy.totalPaidUnits, { compact: true })} USDC
          </dd>
        </div>
        <div>
          <dt>Phases settled</dt>
          <dd>
            {policy.settledCount} / {policy.phaseCount}
          </dd>
        </div>
        <div>
          <dt>Buyer</dt>
          <dd className="is-mono">{shortAddress(policy.buyer)}</dd>
        </div>
      </dl>
    </section>
  );
}
