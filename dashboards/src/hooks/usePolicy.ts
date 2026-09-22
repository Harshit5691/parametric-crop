import { useReadContract, useReadContracts } from "wagmi";

import { contracts } from "../config/chain";
import { policyManagerAbi } from "../contracts/policyManagerAbi";
import { rainfallOracleAbi } from "../contracts/rainfallOracleAbi";

export type Phase = {
  index: number;
  startsAt: number;
  endsAt: number;
  weightBps: number;
  triggerMmX100: number;
  exitMmX100: number;
  settled: boolean;
  paidUnits: bigint;
};

export type Policy = {
  buyer: `0x${string}`;
  sumInsuredUnits: bigint;
  premiumUnits: bigint;
  totalPaidUnits: bigint;
  phaseCount: number;
  settledCount: number;
  closed: boolean;
};

export function usePolicy(policyId: bigint) {
  const { data, isLoading, error, refetch } = useReadContract({
    address: contracts.policyManager,
    abi: policyManagerAbi,
    functionName: "getPolicy",
    args: [policyId],
    query: { retry: false },
  });

  return { policy: data as Policy | undefined, isLoading, error, refetch };
}

/// Every phase of a policy, plus whatever the oracle has published for each.
/// Phases and observations are fetched together so the UI never renders a
/// phase against a stale reading.
export function usePhases(policyId: bigint, phaseCount: number | undefined) {
  const count = phaseCount ?? 0;
  const indices = Array.from({ length: count }, (_, i) => i);

  const phaseReads = useReadContracts({
    contracts: indices.map((i) => ({
      address: contracts.policyManager,
      abi: policyManagerAbi,
      functionName: "getPhase" as const,
      args: [policyId, i] as const,
    })),
    query: { enabled: count > 0 },
  });

  const observationReads = useReadContracts({
    contracts: indices.map((i) => ({
      address: contracts.oracle,
      abi: rainfallOracleAbi,
      functionName: "observation" as const,
      args: [policyId, i] as const,
    })),
    query: { enabled: count > 0 },
  });

  const phases: Phase[] = indices.flatMap((i) => {
    const result = phaseReads.data?.[i];
    if (result?.status !== "success") return [];
    const raw = result.result as {
      startsAt: bigint;
      endsAt: bigint;
      weightBps: number;
      triggerMmX100: number;
      exitMmX100: number;
      settled: boolean;
      paidUnits: bigint;
    };
    return [
      {
        index: i,
        startsAt: Number(raw.startsAt),
        endsAt: Number(raw.endsAt),
        weightBps: Number(raw.weightBps),
        triggerMmX100: Number(raw.triggerMmX100),
        exitMmX100: Number(raw.exitMmX100),
        settled: raw.settled,
        paidUnits: raw.paidUnits,
      },
    ];
  });

  /// settledAt === 0 means the oracle has not published for that phase yet,
  /// which is different from "published a reading of zero".
  const observations = indices.map((i) => {
    const result = observationReads.data?.[i];
    if (result?.status !== "success") return undefined;
    const [observedMmX100, settledAt] = result.result as readonly [number, bigint];
    if (settledAt === 0n) return undefined;
    return { observedMmX100: Number(observedMmX100), settledAt: Number(settledAt) };
  });

  return {
    phases,
    observations,
    isLoading: phaseReads.isLoading || observationReads.isLoading,
    refetch: () => {
      void phaseReads.refetch();
      void observationReads.refetch();
    },
  };
}

/// Phase names follow the crop calendar in pricing/src/parametric/regions.py.
export const PHASE_NAMES = ["Sowing", "Flowering", "Maturity"];

export function phaseName(index: number): string {
  return PHASE_NAMES[index] ?? `Phase ${index + 1}`;
}

/// Calendar months each phase actually occupies in a kharif season.
///
/// Onchain windows are anchored to deploy time so the demo can fast-forward
/// through them, which makes the raw timestamps read as a future season. The
/// agronomic calendar is fixed, so the UI shows that instead of the shifted
/// dates — with the replayed season named explicitly, so nothing is implied to
/// be live data.
export const PHASE_CALENDAR = [
  "15 Jun — 31 Jul",
  "5 Aug — 10 Sep",
  "11 Sep — 15 Oct",
];

export function phaseWindow(index: number): string | undefined {
  return PHASE_CALENDAR[index];
}
