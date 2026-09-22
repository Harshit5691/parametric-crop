import quote from "@pricing/quote.json";
import { formatPct } from "../lib/format";

type HistoryEntry = {
  year: number;
  observed_mm: Record<string, number>;
  payout_inr: number;
};

const history = quote.history as HistoryEntry[];
const pricing = quote.pricing;

/// "This policy would have paid out in N of the last M years."
///
/// The demo's closing panel, and the evidence that the premium is derived from
/// history rather than invented. Data comes from pricing/out/quote.json.
export function BurnHistory() {
  const maxPayout = Math.max(...history.map((h) => h.payout_inr), 1);
  const paidYears = history.filter((h) => h.payout_inr > 0);

  return (
    <section className="burn">
      <div className="burn__head">
        <div>
          <h3>Burn analysis</h3>
          <p className="muted">
            Policy replayed against {pricing.seasons} seasons of rainfall
            history ({pricing.window[0]}–{pricing.window[1]})
          </p>
        </div>
        <p className="burn__headline">
          Would have paid in <strong>{paidYears.length}</strong> of{" "}
          {history.length} seasons
        </p>
      </div>

      <div className="burn__chart" role="img" aria-label="Historical payouts by season">
        {history.map((entry) => {
          const height = (entry.payout_inr / maxPayout) * 100;
          return (
            <div key={entry.year} className="burn__col">
              <div className="burn__bar-wrap">
                <div
                  className={`burn__bar ${entry.payout_inr > 0 ? "is-paid" : ""}`}
                  style={{ height: `${Math.max(height, entry.payout_inr > 0 ? 3 : 0)}%` }}
                  title={`${entry.year}: ₹${entry.payout_inr.toLocaleString("en-IN")}`}
                />
              </div>
              <span className="burn__year">
                {entry.year % 10 === 0 ? entry.year : ""}
              </span>
            </div>
          );
        })}
      </div>

      <dl className="burn__stats">
        <div>
          <dt>Expected loss</dt>
          <dd>{formatPct(pricing.expected_loss_rate)}</dd>
        </div>
        <div>
          <dt>Premium rate</dt>
          <dd>{formatPct(pricing.premium_rate)}</dd>
        </div>
        <div>
          <dt>Hit rate</dt>
          <dd>{formatPct(pricing.hit_rate)}</dd>
        </div>
        <div>
          <dt>Worst season</dt>
          <dd>
            {
              history.reduce((worst, h) =>
                h.payout_inr > worst.payout_inr ? h : worst,
              ).year
            }
          </dd>
        </div>
      </dl>
    </section>
  );
}
