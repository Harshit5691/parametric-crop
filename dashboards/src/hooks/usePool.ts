import { useReadContracts } from "wagmi";

import { contracts } from "../config/chain";
import { poolAbi } from "../contracts/poolAbi";

/// Pool solvency, read straight from the chain.
///
/// This is the transparency claim made concrete: capital, exposure and the
/// ratio between them are all public, so anyone can check the book is backed.
export function usePool() {
  const { data, isLoading, refetch } = useReadContracts({
    contracts: [
      { address: contracts.pool, abi: poolAbi, functionName: "totalAssets" },
      { address: contracts.pool, abi: poolAbi, functionName: "totalReserved" },
      { address: contracts.pool, abi: poolAbi, functionName: "capacity" },
      { address: contracts.pool, abi: poolAbi, functionName: "availableCapacity" },
      { address: contracts.pool, abi: poolAbi, functionName: "solvencyRatioBps" },
      { address: contracts.pool, abi: poolAbi, functionName: "totalShares" },
    ],
  });

  const value = <T,>(i: number): T | undefined =>
    data?.[i]?.status === "success" ? (data[i].result as T) : undefined;

  const totalAssets = value<bigint>(0);
  const totalReserved = value<bigint>(1);

  return {
    totalAssets,
    totalReserved,
    capacity: value<bigint>(2),
    availableCapacity: value<bigint>(3),
    solvencyRatioBps: value<number>(4),
    totalShares: value<bigint>(5),
    /// Share of capital currently backing live policies.
    utilisation:
      totalAssets && totalAssets > 0n && totalReserved !== undefined
        ? Number(totalReserved) / Number(totalAssets)
        : 0,
    isLoading,
    refetch,
  };
}
