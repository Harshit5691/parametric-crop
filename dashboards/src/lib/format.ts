import { USDC_DECIMALS } from "../config/chain";

/// Rainfall is carried onchain as hundredths of a millimetre.
export function mm(mmX100: number | bigint): number {
  return Number(mmX100) / 100;
}

export function formatMm(mmX100: number | bigint): string {
  return `${mm(mmX100).toFixed(1)} mm`;
}

/// Token base units -> a display number.
export function usdc(units: bigint): number {
  return Number(units) / 10 ** USDC_DECIMALS;
}

export function formatUsdc(units: bigint, opts?: { compact?: boolean }): string {
  const value = usdc(units);
  return value.toLocaleString("en-US", {
    maximumFractionDigits: opts?.compact && value >= 1000 ? 0 : 2,
    minimumFractionDigits: 0,
  });
}

export function formatPct(fraction: number): string {
  return `${(fraction * 100).toFixed(1)}%`;
}

/// Basis points -> display percentage.
export function formatBps(bps: number | bigint): string {
  return `${(Number(bps) / 100).toFixed(0)}%`;
}

export function formatDate(unixSeconds: number | bigint): string {
  return new Date(Number(unixSeconds) * 1000).toLocaleDateString("en-GB", {
    day: "numeric",
    month: "short",
    year: "numeric",
  });
}

export function shortAddress(address: string): string {
  return `${address.slice(0, 6)}…${address.slice(-4)}`;
}

/// Where the observed index sits on the gauge, as a fraction of its width.
///
/// The trigger–exit band occupies the middle 70% of the track, leaving headroom
/// either side so readings outside the band still move. Clamping everything
/// outside to the edge made a comfortable 547mm look identical to a marginal
/// 293mm — the gauge went blind exactly where the buyer needs to see margin.
///
/// Above the trigger the marker walks into the right-hand 30% and saturates at
/// one full band-width clear; below exit it does the same on the left.
export function indexPosition(
  observedMmX100: number,
  triggerMmX100: number,
  exitMmX100: number,
): number {
  const BAND_START = 0.15;
  const BAND_WIDTH = 0.7;

  const span = triggerMmX100 - exitMmX100;
  if (span <= 0) return 1;

  const withinBand = (observedMmX100 - exitMmX100) / span;
  if (withinBand >= 0 && withinBand <= 1) {
    return BAND_START + withinBand * BAND_WIDTH;
  }

  // Outside the band: map one further band-width onto the remaining margin.
  const overshoot = Math.min(1, Math.abs(withinBand > 1 ? withinBand - 1 : withinBand));
  return withinBand > 1
    ? BAND_START + BAND_WIDTH + overshoot * BAND_START
    : BAND_START - overshoot * BAND_START;
}

/// Mirror of PayoutMath.payoutFractionBps, for previewing a payout in the UI
/// before it settles. The authoritative number always comes from the contract.
export function payoutFraction(
  observedMmX100: number,
  triggerMmX100: number,
  exitMmX100: number,
): number {
  if (exitMmX100 >= triggerMmX100) return 0;
  if (observedMmX100 >= triggerMmX100) return 0;
  if (observedMmX100 <= exitMmX100) return 1;
  return (triggerMmX100 - observedMmX100) / (triggerMmX100 - exitMmX100);
}
