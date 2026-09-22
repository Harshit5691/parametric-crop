import type { Phase } from "../hooks/usePolicy";
import { phaseName, phaseWindow } from "../hooks/usePolicy";
import {
  formatBps,
  formatMm,
  formatUsdc,
  indexPosition,
  payoutFraction,
} from "../lib/format";

type Props = {
  phase: Phase;
  observation?: { observedMmX100: number; settledAt: number };
  sumInsuredUnits: bigint;
};

/// One crop phase: its window, thresholds, and where the rainfall index
/// currently sits against them.
///
/// The gauge is the core of the demo — a judge should see at a glance that the
/// index is tracking below the trigger and that a payout follows mechanically.
export function PhaseCard({ phase, observation, sumInsuredUnits }: Props) {
  const exposure = (sumInsuredUnits * BigInt(phase.weightBps)) / 10_000n;

  const hasReading = observation !== undefined;
  const observed = observation?.observedMmX100 ?? 0;

  const position = hasReading
    ? indexPosition(observed, phase.triggerMmX100, phase.exitMmX100)
    : 1;
  const fraction = hasReading
    ? payoutFraction(observed, phase.triggerMmX100, phase.exitMmX100)
    : 0;

  const projectedPayout =
    (exposure * BigInt(Math.round(fraction * 10_000))) / 10_000n;

  const status = !hasReading
    ? { label: "Awaiting oracle", tone: "pending" as const }
    : phase.settled
      ? phase.paidUnits > 0n
        ? { label: "Paid", tone: "paid" as const }
        : { label: "Settled — no payout", tone: "safe" as const }
      : fraction > 0
        ? { label: "Below trigger", tone: "alert" as const }
        : { label: "Above trigger", tone: "safe" as const };

  return (
    <article className={`phase-card phase-card--${status.tone}`}>
      <header className="phase-card__head">
        <div>
          <h3>{phaseName(phase.index)}</h3>
          <p className="phase-card__window">{phaseWindow(phase.index)}</p>
        </div>
        <div className="phase-card__meta">
          <span className={`badge badge--${status.tone}`}>{status.label}</span>
          <span className="phase-card__weight">
            {formatBps(phase.weightBps)} of cover
          </span>
        </div>
      </header>

      <div className="gauge">
        <div className="gauge__track">
          {/* Payout region: everything at or below the trigger. */}
          <div className="gauge__payout-zone" />
          {/* Threshold ticks, matching the band in indexPosition. */}
          <div className="gauge__tick" style={{ left: "15%" }} />
          <div className="gauge__tick" style={{ left: "85%" }} />
          {hasReading && (
            <div
              className="gauge__marker"
              style={{ left: `${position * 100}%` }}
              aria-label={`Observed ${formatMm(observed)}`}
            />
          )}
        </div>
        <div className="gauge__labels">
          <span>
            <strong>{formatMm(phase.exitMmX100)}</strong>
            <em>exit — full payout</em>
          </span>
          <span className="gauge__labels-right">
            <strong>{formatMm(phase.triggerMmX100)}</strong>
            <em>trigger — payout begins</em>
          </span>
        </div>
      </div>

      <dl className="phase-card__stats">
        <div>
          <dt>Observed index</dt>
          <dd>{hasReading ? formatMm(observed) : "—"}</dd>
        </div>
        <div>
          <dt>Phase exposure</dt>
          <dd>{formatUsdc(exposure, { compact: true })} USDC</dd>
        </div>
        <div>
          <dt>{phase.settled ? "Paid" : "Projected payout"}</dt>
          <dd className={fraction > 0 || phase.paidUnits > 0n ? "is-payout" : ""}>
            {phase.settled
              ? `${formatUsdc(phase.paidUnits, { compact: true })} USDC`
              : hasReading
                ? `${formatUsdc(projectedPayout, { compact: true })} USDC`
                : "—"}
          </dd>
        </div>
      </dl>
    </article>
  );
}
