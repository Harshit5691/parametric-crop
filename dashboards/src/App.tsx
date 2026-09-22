import { useEffect } from "react";
import { useBlockNumber } from "wagmi";

import { BurnHistory } from "./components/BurnHistory";
import { PhaseCard } from "./components/PhaseCard";
import { PolicySummary } from "./components/PolicySummary";
import { PoolStatus } from "./components/PoolStatus";
import { usePhases, usePolicy } from "./hooks/usePolicy";
import quote from "@pricing/quote.json";

const POLICY_ID = 1n;

export function App() {
  const { policy, isLoading, error, refetch } = usePolicy(POLICY_ID);
  const { phases, observations, refetch: refetchPhases } = usePhases(
    POLICY_ID,
    policy?.phaseCount,
  );

  // Re-read on every block so the payout lands live during the demo rather
  // than after a manual refresh.
  const { data: blockNumber } = useBlockNumber({ watch: true });
  useEffect(() => {
    void refetch();
    refetchPhases();
  }, [blockNumber, refetch, refetchPhases]);

  return (
    <div className="page">
      <header className="masthead">
        <div>
          <p className="eyebrow">Parametric crop protection</p>
          <h1>Buyer dashboard</h1>
        </div>
        <p className="masthead__tag">
          Drought cover that pays in days, not months — no claim, no adjuster.
        </p>
      </header>

      {isLoading && <p className="muted">Reading policy from chain…</p>}

      {error && (
        <div className="notice notice--error">
          <strong>No policy found onchain.</strong>
          <p>
            Deploy the contracts and write a policy first — see{" "}
            <code>contracts/README.md</code>. The dashboard reads policy #
            {POLICY_ID.toString()} from the address in{" "}
            <code>src/contracts/addresses.json</code>.
          </p>
        </div>
      )}

      {policy && (
        <>
          <PolicySummary
            policyId={POLICY_ID}
            policy={policy}
            region={quote.policy.region}
            crop={quote.policy.crop}
          />

          <section className="phases">
            <h3>Crop calendar</h3>
            <div className="phases__grid">
              {phases.map((phase) => (
                <PhaseCard
                  key={phase.index}
                  phase={phase}
                  observation={observations[phase.index]}
                  sumInsuredUnits={policy.sumInsuredUnits}
                />
              ))}
            </div>
          </section>
        </>
      )}

      <PoolStatus />
      <BurnHistory />

      <footer className="footer">
        <p>
          Index: {quote.policy.index} · cell {quote.policy.lat}°N{" "}
          {quote.policy.lon}°E · pricing source{" "}
          {quote.provenance.source}
        </p>
        <p className="muted">
          Basis risk is real: the index can miss a loss this field actually
          suffered. Finer cells, phase weighting and multi-source settlement
          shrink it; they do not remove it.
        </p>
      </footer>
    </div>
  );
}
